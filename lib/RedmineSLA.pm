package RedmineSLA;

use Business::Hours;
use DateTime;
use DateTime::Format::Strptime;
use DBI;

=head1 RedmineSLA

=cut

sub new {
    my $self   = shift;
    my $params = shift;

    my $dsn =
"DBI:mysql:database=$params->{database};host=$params->{hostname};port=$params->{port}";
    my $dbh = DBI->connect( $dsn, $params->{username}, $params->{password} );

    $self->{dbh}  = $dbh;
    $self->{strp} = DateTime::Format::Strptime->new(
        pattern  => "%Y-%m-%d %H:%M:%S",
        on_error => sub { die $_[0] . ":" . $_[1]; },
        strict   => 1
    );
    $self->{bh} = $self->bh( $params->{business_hours} );

# Custom Redmine field "Organization". Excpecting a string value (organization name), not id.
# Users in this organization are considered admins.
    $self->{admin_organization} = $params->{admin_organization};
    $self->{project_ids}        = $params->{project_ids};
    $self->{start_date}         = $params->{start_date};
    $self->{issue_statuses}     = $self->get_issue_statuses;
    $self->{issue_priorities}   = $self->get_issue_priorities;
    $self->{admin_users}        = $self->get_users_admin;
    $self->{sla_statuses}       = $params->{sla_statuses} // [
        $self->{issue_statuses}->{New},
        $self->{issue_statuses}->{"In Progress"},
        $self->{issue_statuses}->{Feedback}
    ];
    return $self;
}

sub get_sla_issues {
    my $self = shift;

    my $dbh                      = $self->{dbh};
    my $project_ids_placeholders = join ", ", ("?") x @{ $self->{project_ids} };
    my $admin_users_placeholders = join ", ", ("?") x @{ $self->{admin_users} };
    my $sth                      = $dbh->prepare(
"SELECT * FROM issues WHERE project_id IN ($project_ids_placeholders) AND priority_id != ? AND status_id = ? AND author_id NOT IN ($admin_users_placeholders) AND created_on >= ?"
    );
    $sth->execute(
        @{ $self->{project_ids} },         $self->{issue_priorities}->{Low},
        $self->{issue_statuses}->{Closed}, @{ $self->{admin_users} },
        $self->{start_date}
    );

    my @issues;
    while ( my $row = $sth->fetchrow_hashref ) {
        push(
            @issues,
            {
                created_on             => $row->{created_on},
                id                     => $row->{id},
                closed_on              => $row->{closed_on},
                first_assigned_to      => undef,
                first_response_on      => undef,
                first_response_hours   => undef,
                first_response_seconds => undef,
                first_status_id        => undef,
                resolution_hours       => 0,
                resolution_seconds     => 0,
                subject                => $row->{subject}
            }
        );
    }

    foreach my $issue (@issues) {
        my @events;
        my $issue_created_on_dt = $self->strp( $issue->{created_on} );
        $sth = $dbh->prepare(
"SELECT id, user_id, created_on FROM journals WHERE journalized_type=? AND journalized_id=? ORDER BY created_on ASC;"
        );
        $sth->execute( "Issue", $issue->{id} );

        while ( my $journal = $sth->fetchrow_hashref ) {
            my $event = {
                created_on => $journal->{created_on},
                user_id    => $journal->{user_id},
                changes    => [],
            };
            my $is_first_response = 0;
            if (  !$issue->{first_response_on}
                && $self->is_user_admin( $journal->{user_id} ) )
            {
                my $dt = $self->strp( $journal->{created_on} );
                $issue->{first_response_on} //= DateTime->from_epoch(
                    epoch => $self->bh->first_after( $dt->epoch ) );
                my $icbepoch =
                  $self->bh->first_after( $issue_created_on_dt->epoch ) + 1;
                my $jcbepoch = $self->bh->first_after( $dt->epoch ) + 1;
                $self->bh->for_timespan( Start => $icbepoch, End => $jcbepoch );
                $issue->{first_response_hours} //= sprintf( "%.2f",
                    ( $self->bh->between( $icbepoch, $jcbepoch ) / 60 / 60 ) );
                $issue->{first_response_seconds} //=
                  $self->bh->between( $icbepoch, $jcbepoch );
                $is_first_response = 1;
            }

            my $sth2 = $dbh->prepare(
"SELECT prop_key, old_value, value FROM journal_details WHERE property=? AND journal_id=? AND prop_key IN ('assigned_to_id', 'status_id') ORDER BY prop_key ASC;"
            );
            $sth2->execute( "attr", $journal->{id} );

            my @minievents;
            while ( my $journal_event = $sth2->fetchrow_hashref ) {
                push(
                    @minievents,
                    {
                        event     => $journal_event->{prop_key},
                        old_value => $journal_event->{old_value},
                        value     => $journal_event->{value},
                    }
                );
                if (   !$issue->{first_assigned_to}
                    and $journal_event->{prop_key} eq "assigned_to_id" )
                {
                    $issue->{first_assigned_to} = $journal_event->{old_value};
                }
                if (   !$issue->{first_status_id}
                    and $journal_event->{prop_key} eq "status_id" )
                {
                    $issue->{first_status_id} = $journal_event->{old_value};
                }
            }
            if ( scalar(@minievents) > 0 ) {
                $event->{changes} = \@minievents;
                push( @events, $event );
            }
            elsif ($is_first_response) {
                push( @events, $event );
            }
        }

        $issue->{events} = \@events;

        unless ( $self->is_user_admin( $issue->{first_assigned_to} ) ) {
            warn
"Issue $issue->{id} not first assigned to admin! $current_assignee";
            next;
        }

        my $sla_counting_datetime;
        my $is_sla_counting  = 0;
        my $current_assignee = $issue->{first_assigned_to};
        my $current_status   = $issue->{first_status_id};
        foreach my $event (@events) {
            if ( !$sla_counting_datetime ) {
                if ( $self->is_user_admin( $event->{user_id} ) ) {
                    $sla_counting_datetime =
                      $self->strp( $event->{created_on} );
                    foreach my $change ( @{ $event->{changes} } ) {
                        if ( $change->{event} eq "assigned_to_id" ) {
                            $current_assignee = $change->{value};
                        }
                        elsif ( $change->{event} eq "status_id" ) {
                            $current_status = $change->{value};
                        }
                    }
                    if (   $self->is_user_admin($current_assignee)
                        && $self->is_status_sla($current_status) )
                    {
                        $is_sla_counting = 1;
                    }
                    next;
                }
                else {
                    next;
                }
            }

            if ($is_sla_counting) {
                my $event_dt = $self->strp( $event->{created_on} );
                my $slacbepoch =
                  $self->bh->first_after( $sla_counting_datetime->epoch );
                my $jcbepoch = $self->bh->first_after( $event_dt->epoch );
                $self->bh->for_timespan(
                    Start => $slacbepoch,
                    End   => $jcbepoch
                );
                $issue->{resolution_seconds} +=
                  $self->bh->between( $slacbepoch, $jcbepoch );
                $sla_counting_datetime = $event_dt;
            }

            foreach my $change ( @{ $event->{changes} } ) {
                if ( $change->{event} eq "assigned_to_id" ) {
                    $current_assignee = $change->{value};
                }
                elsif ( $change->{event} eq "status_id" ) {
                    $current_status = $change->{value};
                }
            }
            if (   $self->is_user_admin($current_assignee)
                && $self->is_status_sla($current_status) )
            {
                my $event_dt = $self->strp( $event->{created_on} );
                $is_sla_counting       = 1;
                $sla_counting_datetime = $event_dt;
            }
            else {
                $is_sla_counting = 0;
            }

        }
        $issue->{resolution_hours} =
          sprintf( "%.2f", $issue->{resolution_seconds} / 60 / 60 );
    }

    return \@issues;
}

sub strp {
    my $self   = shift;
    my $string = shift;
    return $self->{strp}->parse_datetime($string);
}

sub get_issue_priorities {
    my $self = shift;

    my $dbh = $self->{dbh};
    my $sth = $dbh->prepare("SELECT name, id FROM enumerations WHERE type=?;");
    $sth->execute("IssuePriority");

    my $priorities = {};
    while ( my $row = $sth->fetchrow_hashref ) {
        $priorities->{ $row->{name} } = $row->{id};
    }

    return $priorities;
}

sub get_issue_statuses {
    my $self = shift;

    my $dbh = $self->{dbh};
    my $sth = $dbh->prepare("SELECT * FROM issue_statuses;");
    $sth->execute();

    my $statuses = {};
    while ( my $row = $sth->fetchrow_hashref ) {
        $statuses->{ $row->{name} } = $row->{id};
    }

    return $statuses;
}

sub get_users_admin {
    my $self = shift;

    my $dbh = $self->{dbh};
    my $sth = $dbh->prepare("SELECT id FROM custom_fields WHERE name=?;");
    $sth->execute("Organization");

    my $organization_field_id = $sth->fetchrow_hashref->{id};
    my $sth                   = $dbh->prepare(
"SELECT customized_id FROM custom_values WHERE custom_field_id=? AND value=?;"
    );
    $sth->execute( $organization_field_id, $self->{admin_organization} );

    my @admins;
    while ( my $user = $sth->fetchrow_hashref ) {
        push( @admins, $user->{customized_id} );
    }

    return \@admins;
}

sub is_user_admin {
    my $self    = shift;
    my $user_id = shift;

    return 0 unless $user_id;
    return 1 if grep( /^$user_id$/, @{ $self->{admin_users} } );
    return 0;
}

sub is_status_sla {
    my $self      = shift;
    my $status_id = shift;

    return 0 unless $status_id;
    return 1 if grep( /^$status_id$/, @{ $self->{sla_statuses} } );
    return 0;
}

sub bh {
    my $self  = shift;
    my $hours = shift;

    return $self->{bh} if $self->{bh};

    my $bh = Business::Hours->new;
    $bh->business_hours(%$hours);
    return $bh;
}

1;
