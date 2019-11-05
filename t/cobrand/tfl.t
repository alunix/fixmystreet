use FixMyStreet::TestMech;
use FixMyStreet::App;
use FixMyStreet::Script::Reports;

# disable info logs for this test run
FixMyStreet::App->log->disable('info');
END { FixMyStreet::App->log->enable('info'); }

my $mech = FixMyStreet::TestMech->new;

my $body = $mech->create_body_ok(2482, 'TfL');
my $superuser = $mech->create_user_ok('superuser@example.com', name => 'Super User', is_superuser => 1);
my $staffuser = $mech->create_user_ok('counciluser@example.com', name => 'Council User', from_body => $body);
$staffuser->user_body_permissions->create({
    body => $body,
    permission_type => 'contribute_as_body',
});
$staffuser->user_body_permissions->create({
    body => $body,
    permission_type => 'default_to_body',
});
my $user = $mech->create_user_ok('londonresident@example.com');

my $bromley = $mech->create_body_ok(2482, 'Bromley');
my $bromleyuser = $mech->create_user_ok('bromleyuser@bromley.example.com', name => 'Bromley Staff', from_body => $bromley);


my $contact1 = $mech->create_contact_ok(
    body_id => $body->id,
    category => 'Bus stops',
    email => 'busstops@example.com',
);
my $contact2 = $mech->create_contact_ok(
    body_id => $body->id,
    category => 'Traffic lights',
    email => 'trafficlights@example.com',
);

FixMyStreet::override_config {
    ALLOWED_COBRANDS => 'tfl',
    MAPIT_URL => 'http://mapit.uk/',
    COBRAND_FEATURES => {
        internal_ips => {
            tfl => [ '127.0.0.1' ]
        },
        anonymous_account => {
            tfl => 'anonymous'
        }
    }
}, sub {

subtest "test report creation anonymously by button" => sub {
    $mech->get_ok('/around');
    $mech->submit_form_ok( { with_fields => { pc => 'BR1 3UH', } }, "submit location" );
    $mech->follow_link_ok( { text_regex => qr/skip this step/i, }, "follow 'skip this step' link" );
    $mech->submit_form_ok(
        {
            button => 'submit_register',
            with_fields => {
                title => 'Anonymous Test Report 1',
                detail => 'Test report details.',
                name => 'Joe Bloggs',
                may_show_name => '1',
                category => 'Bus stops',
            }
        },
        "submit good details"
    );

    is_deeply $mech->page_errors, [
        'Please enter your email'
    ], "check there were no errors";

    $mech->get_ok('/around');
    $mech->submit_form_ok( { with_fields => { pc => 'BR1 3UH', } }, "submit location" );
    $mech->follow_link_ok( { text_regex => qr/skip this step/i, }, "follow 'skip this step' link" );
    $mech->submit_form_ok(
        {
            button => 'report_anonymously',
            with_fields => {
                title => 'Anonymous Test Report 1',
                detail => 'Test report details.',
                category => 'Bus stops',
            }
        },
        "submit good details"
    );
    my $report = FixMyStreet::DB->resultset("Problem")->find({ title => 'Anonymous Test Report 1'});
    ok $report, "Found the report";

    $mech->content_contains('Your issue is on its way to TfL');
    $mech->content_contains('Your reference for this report is FMS' . $report->id) or diag $mech->content;

    is_deeply $mech->page_errors, [], "check there were no errors";

    is $report->state, 'confirmed', "report confirmed";
    $mech->get_ok( '/report/' . $report->id );

    is $report->bodies_str, $body->id;
    is $report->name, 'Anonymous user';
    like $report->user->email, qr/anonymous-[2-9a-km-zA-NP-Z]{18}\@tfl.gov.uk/;
    is $report->anonymous, 1; # Doesn't change behaviour here, but uses anon account's name always
    is $report->get_extra_metadata('contributed_as'), 'anonymous_user';

    my $alert = FixMyStreet::App->model('DB::Alert')->find( {
        user => $report->user,
        alert_type => 'new_updates',
        parameter => $report->id,
    } );
    is $alert, undef, "no alert created";

    $mech->not_logged_in_ok;
};

subtest "test report creation anonymously by staff user" => sub {
    $mech->log_in_ok( $staffuser->email );
    $mech->get_ok('/around');
    $mech->submit_form_ok( { with_fields => { pc => 'BR1 3UH', } }, "submit location" );
    $mech->follow_link_ok( { text_regex => qr/skip this step/i, }, "follow 'skip this step' link" );
    $mech->submit_form_ok(
        {
            button => 'report_anonymously',
            with_fields => {
                title => 'Anonymous Test Report 2',
                detail => 'Test report details.',
                category => 'Bus stops',
            }
        },
        "submit good details"
    );
    is_deeply $mech->page_errors, [], "check there were no errors";

    my $report = FixMyStreet::DB->resultset("Problem")->find({ title => 'Anonymous Test Report 2'});
    ok $report, "Found the report";

    $mech->content_contains('Your issue is on its way to TfL');
    $mech->content_contains('Your reference for this report is FMS' . $report->id) or diag $mech->content;

    is $report->state, 'confirmed', "report confirmed";
    $mech->get_ok( '/report/' . $report->id );

    is $report->bodies_str, $body->id;
    is $report->name, 'Anonymous user';
    like $report->user->email, qr/anonymous-[2-9a-km-zA-NP-Z]{18}\@tfl.gov.uk/;
    is $report->anonymous, 1;
    is $report->get_extra_metadata('contributed_as'), 'anonymous_user';

    my $alert = FixMyStreet::App->model('DB::Alert')->find( {
        user => $report->user,
        alert_type => 'new_updates',
        parameter => $report->id,
    } );
    is $alert, undef, "no alert created";

    $mech->log_out_ok;
};

subtest "reports have unique users" => sub {
    my ($report1, $report2) = FixMyStreet::DB->resultset("Problem")->all;

    isnt $report1->user->id, $report2->user->id, 'reports have different users';
    isnt $report1->user->email, $report2->user->email, 'anonymous users have different email addresses';
};

FixMyStreet::DB->resultset("Problem")->delete_all;

subtest "test report creation and reference number" => sub {
    $mech->log_in_ok( $user->email );
    $mech->get_ok('/around');
    $mech->submit_form_ok( { with_fields => { pc => 'BR1 3UH', } }, "submit location" );
    $mech->follow_link_ok( { text_regex => qr/skip this step/i, }, "follow 'skip this step' link" );
    $mech->submit_form_ok(
        {
            with_fields => {
                title => 'Test Report 1',
                detail => 'Test report details.',
                name => 'Joe Bloggs',
                may_show_name => '1',
                category => 'Bus stops',
            }
        },
        "submit good details"
    );

    my $report = FixMyStreet::DB->resultset("Problem")->find({ title => 'Test Report 1'});
    ok $report, "Found the report";

    $mech->content_contains('Your issue is on its way to TfL');
    $mech->content_contains('Your reference for this report is FMS' . $report->id) or diag $mech->content;

    is_deeply $mech->page_errors, [], "check there were no errors";

    is $report->state, 'confirmed', "report confirmed";

    is $report->bodies_str, $body->id;
    is $report->name, 'Joe Bloggs';

    $mech->log_out_ok;
};

subtest "reference number included in email" => sub {
    my $report = FixMyStreet::DB->resultset("Problem")->find({ title => 'Test Report 1'});
    my $id = $report->id;

    $mech->clear_emails_ok;
    FixMyStreet::Script::Reports::send();
    my @email = $mech->get_email;
    is $email[0]->header('To'), 'TfL <busstops@example.com>';
    like $mech->get_text_body_from_email($email[0]), qr/Report reference: FMS$id/, "FMS-prefixed ID in TfL email";
    is $email[1]->header('To'), $report->user->email;
    like $mech->get_text_body_from_email($email[1]), qr/report's reference number is FMS$id/, "FMS-prefixed ID in reporter email";
    $mech->clear_emails_ok;

    $mech->get_ok( '/report/' . $report->id );
    $mech->content_contains('FMS' . $report->id) or diag $mech->content;
};

subtest 'check lookup by reference' => sub {
    my $id = FixMyStreet::DB->resultset("Problem")->first->id;

    $mech->get_ok('/');
    $mech->submit_form_ok( { with_fields => { pc => 'FMS12345' } }, 'bad ref');
    $mech->content_contains('Searching found no reports');

    $mech->get_ok('/');
    $mech->submit_form_ok( { with_fields => { pc => "FMS$id" } }, 'good FMS-prefixed ref');
    is $mech->uri->path, "/report/$id", "redirected to report page when using FMS-prefixed ref";

    $mech->get_ok('/');
    $mech->submit_form_ok( { with_fields => { pc => "fms $id" } }, 'good FMS-prefixed with a space ref');
    is $mech->uri->path, "/report/$id", "redirected to report page when using FMS-prefixed ref";

    $mech->get_ok('/');
    $mech->submit_form_ok( { with_fields => { pc => "$id" } }, 'good ref');
    is $mech->uri->path, "/report/$id", "redirected to report page when using non-prefixed ref";
};

for my $test (
    {
        states => [ 'confirmed' ],
        colour => 'red'
    },
    {
        states => ['action scheduled', 'in progress', 'investigating', 'planned'],
        colour => 'orange'
    },
    {
        states => [ FixMyStreet::DB::Result::Problem->fixed_states, FixMyStreet::DB::Result::Problem->closed_states ],
        colour => 'green'
    },
) {
    subtest 'check ' . $test->{colour} . ' pin states' => sub {
        my $report = FixMyStreet::DB->resultset("Problem")->find({ title => 'Test Report 1'});
        my $url = '/around?ajax=1&bbox=' . ($report->longitude - 0.01) . ',' .  ($report->latitude - 0.01)
            . ',' . ($report->longitude + 0.01) . ',' .  ($report->latitude + 0.01);

        for my $state ( @{ $test->{states} } ) {
            $report->update({ state => $state });
            my $json = $mech->get_ok_json( $url );
            my $colour = $json->{pins}[0][2];
            is $colour, $test->{colour}, 'correct ' . $test->{colour} . ' pin for state ' . $state;
        }
    };
}

subtest 'Dashboard extra columns' => sub {
    subtest 'extra CSV column present' => sub {
        $mech->log_in_ok( $staffuser->email );
        $mech->get_ok('/dashboard?export=1');
        $mech->content_contains(',Borough,"Safety critical"');
        $mech->content_contains('Bromley,No');
        my $report = FixMyStreet::DB->resultset("Problem")->find({ title => 'Test Report 1'});
        $report->set_extra_fields({ name => 'severity', value => 'Yes', safety_critical => 1 });
        $report->update;
        $mech->get_ok('/dashboard?export=1');
        $mech->content_contains(',Borough,"Safety critical"');
        $mech->content_contains('Bromley,Yes');
    };
};

subtest 'check report age on /around' => sub {
    my $report = FixMyStreet::DB->resultset("Problem")->find({ title => 'Test Report 1'});
    $report->update({ state => 'confirmed' });

    $mech->get_ok( '/around?lat=' . $report->latitude . '&lon=' . $report->longitude );
    $mech->content_contains($report->title);

    $report->update({
        confirmed => \"current_timestamp-'7 weeks'::interval",
        whensent => \"current_timestamp-'7 weeks'::interval",
        lastupdate => \"current_timestamp-'7 weeks'::interval",
    });

    $mech->get_ok( '/around?lat=' . $report->latitude . '&lon=' . $report->longitude );
    $mech->content_lacks($report->title);
};

subtest 'TfL admin allows inspectors to be assigned to borough areas' => sub {
    $mech->log_in_ok($superuser->email);

    $mech->get_ok("/admin/users/" . $staffuser->id) or diag $mech->content;

    $mech->submit_form_ok( { with_fields => {
        area_ids => [2482],
    } } );

    $staffuser->discard_changes;
    is_deeply $staffuser->area_ids, [2482], "User assigned to Bromley LBO area";

    $staffuser->update({ area_ids => undef}); # so login below doesn't break
};

subtest 'Leave an update on a shortlisted report, get an email' => sub {
    my $report = FixMyStreet::DB->resultset("Problem")->find({ title => 'Test Report 1'});
    $staffuser->add_to_planned_reports($report);
    $mech->log_in_ok( $user->email );
    $mech->get_ok('/report/' . $report->id);
    $mech->submit_form_ok({ with_fields => { update => 'This is an update' }});
    my $email = $mech->get_text_body_from_email;
    like $email, qr/This is an update/;
};

subtest 'TfL staff can access TfL admin' => sub {
    $mech->log_in_ok( $staffuser->email );
    $mech->get_ok('/admin');
    $mech->content_contains( 'This is the administration interface for' );
    $mech->log_out_ok;
};

subtest 'Bromley staff cannot access TfL admin' => sub {
    $mech->log_in_ok( $bromleyuser->email );
    ok $mech->get('/admin');
    is $mech->res->code, 403, "got 403";
    $mech->log_out_ok;
};

};

FixMyStreet::override_config {
    ALLOWED_COBRANDS => 'bromley',
    MAPIT_URL => 'http://mapit.uk/'
}, sub {

subtest 'Bromley staff can access Bromley admin' => sub {
    $mech->log_in_ok( $bromleyuser->email );
    $mech->get_ok('/admin');
    $mech->content_contains( 'This is the administration interface for' );
    $mech->log_out_ok;
};

subtest 'TfL staff cannot access Bromley admin' => sub {
    $mech->log_in_ok( $staffuser->email );
    ok $mech->get('/admin');
    is $mech->res->code, 403, "got 403";
    $mech->log_out_ok;
};

};

done_testing();
