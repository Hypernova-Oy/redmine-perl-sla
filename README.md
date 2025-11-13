# redmine-perl-sla

A simple Perl module that connects to a Redmine MySQL database and calculates
response and resolution durations, excluding business hours and public holidays.

Response time is counted from the creation of the issue to the first action
committed by an user in an organization defined in `admin_organization`.

Resolution time is counted from the creation to the closure of the issue.
Counting is paused whenever the assignee is someone else than a member of
the `admin_organization`, or when the issue is in another status than
`New`, `In Progress` or `Feedback`.

Add it to your Redmine server's crontab and let it generate a daily Redmine wiki
report.

## Usage

See [example.pl](example.pl)

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

### RedmineSLA->update_wiki_report

This updates (or first, creates it) a wiki page called `SLA` to the project id of the first element of `project_ids` passed to `new()`.
 
## LICENSE

GPLv3
