# redmine-perl-sla

A simple Perl module that connects to a Redmine MySQL database and calculates
response and resolution durations, excluding business hours and public holidays.

## Usage

```
my $sla = RedmineSLA->new({
  database => "redmine",
  hostname => "localhost",
  port => 3306,
  username => "username",
  password => "password",
  project_ids => [1],
  admin_organization => "Hypernova Oy",
  start_date => "2025-01-01 00:00:00",
  business_hours => {
    0 => { Name  => "Sunday",
           Start => undef,
           End   => undef, },
    1 => { Name  => "Monday",
           Start => "08:00",
           End   => "16:00", },
    2 => { Name  => "Tuesday",
           Start => "08:00",
           End   => "16:00", },
    3 => { Name  => "Wednesday",
           Start => "08:00",
           End   => "16:00", },
    4 => { Name  => "Thursday",
           Start => "08:00",
           End   => "16:00", },
    5 => { Name  => "Friday",
           Start => "08:00",
           End   => "16:00", },
    6 => { Name  => "Saturday",
           Start => undef,
           End   => undef, },
    holidays => [qw(2025-01-01 2025-12-25)],
  },
});

my $RED="\033[0;31m";
my $NC="\033[0m";
my $response = 16; # maximum allowed hours to first customer support response
my $resolution = 32; # maximum allowed hours to resolving an issue

print("Response exceeded   > ${RED}${response}${NC} hours\n");
print("Resolution exceeded > ${RED}${resolution}${NC} hours\n");
print("\n\n");

print sprintf("%-19s", "Date")."\t".sprintf("%-40s", "Subject")."\t".sprintf("%-42s", "URL")."\tResponse (h)\tResolution (h)\n";
foreach my $issue (reverse @{$sla->get_sla_issues}) {
    my $response_hours = $issue->{first_response_hours};
    my $response_hours_formatted = sprintf("%-14s", $response_hours);
    if ($response_hours >= $response) {
      $response_hours_formatted = "${RED}${response_hours_formatted}${NC}";
    }

    my $resolution_hours = $issue->{resolution_hours};
    my $resolution_hours_formatted = sprintf("%-14s", $resolution_hours);
    if ($resolution_hours >= $resolution) {
      $resolution_hours_formatted = "${RED}${resolution_hours_formatted}${NC}";
    }

    my $subject = sprintf("%-37s", substr($issue->{subject}, 0, 36));

    print "$issue->{created_on}\t$subject\thttps://redmine.hypernova.fi/issues/$issue->{id}\t\t$response_hours_formatted\t$resolution_hours_formatted";
    print "\n";
}
```

Outputs

```
Response exceeded   > 16 hours
Resolution exceeded > 32 hours


Date               	Subject                                 	URL                                       	Response (h)	Resolution (h)
2025-09-12 08:41:19	newest issue                      	https://redmine.hypernova.fi/issues/4    	      	13.31         	0.31          
2025-06-25 09:15:44	a bit tougher issue               	https://redmine.hypernova.fi/issues/3           	17.74         	235.31        
2025-06-05 10:49:59	a bit more older issue            	https://redmine.hypernova.fi/issues/2	        	2.17          	0.76          
2025-06-02 09:20:10	instantly resolved                	https://redmine.hypernova.fi/issues/1    	       	5.66          	0.00          
```

### RedmineSLA->get_sla_issues

Returns an arrayref of issues

Issue has the following hashref structure:

```
{
    'first_assigned_to' => '2',
    'created_on' => '2025-01-01 09:00:00',
    'events' => [
        {
        'changes' => [
                        {
                            'value' => '2',
                            'old_value' => '1',
                            'event' => 'status_id'
                        }
                        ],
        'user_id' '1',
        'created_on' => '2025-01-01 10:00:00'
        },
        {
        'user_id' '1',
        'changes' => [
                        {
                            'value' => '1',
                            'event' => 'assigned_to_id',
                            'old_value' => '2'
                        }
                        ],
        'created_on' => '2025-01-01 09:06:00'
        },
        ...
    ],
    'closed_on' => '2025-01-01 10:00:00',
    'resolution_seconds' => 7200,
    'first_response_hours' => '1',
    'first_response_seconds' => 3600,
    'subject' => 'first issue',
    'first_status_id' => '1',
    'resolution_hours' => '2',
    'first_response_on' => (DateTime object)
    'id' => 1
}
```

## LICENSE

GPLv3
