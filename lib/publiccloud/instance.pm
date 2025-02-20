# SUSE's openQA tests
#
# Copyright 2018 SUSE LLC
# SPDX-License-Identifier: FSFAP

# Summary: Base class for public cloud instances
#
# Maintainer: Clemens Famulla-Conrad <cfamullaconrad@suse.de>

package publiccloud::instance;
use testapi;
use Carp 'croak';
use Mojo::Base -base;
use Mojo::Util 'trim';
use File::Basename;
use publiccloud::utils;
use version_utils;

use constant SSH_TIMEOUT => 90;

has instance_id => undef;    # unique CSP instance id
has public_ip => undef;    # public IP of instance
has username => undef;    # username for ssh connection
has ssh_key => undef;    # path to ssh-key for connection
has image_id => undef;    # image from where the VM is booted
has type => undef;
has provider => undef, weak => 1;    # back reference to the provider
has ssh_opts => '-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR';

=head2 run_ssh_command

    run_ssh_command(cmd => 'command'[, timeout => 90][, ssh_opts =>'..'][, username => 'XXX'][, no_quote => 0][, rc_only => 0]);

Runs a command C<cmd> via ssh in the given VM. Retrieves the output.
If the command retrieves not zero, a exception is thrown..
Timeout can be set by C<timeout> or 90 sec by default.
C<<proceed_on_failure=>1>> allows to proceed with validation when C<cmd> is
failing (return non-zero exit code)
By default, the command is passed in single quotes to SSH.
To avoid quoting use C<<no_quote=>1>>.
With C<<ssh_opts=>'...'>> you can overwrite all default ops which are in
C<<$instance->ssh_opts>>.
Use argument C<username> to specify a different username then
C<<$instance->username()>>.
Use argument C<rc_only> to only check for the return code of the command.
=cut
sub run_ssh_command {
    my $self = shift;
    my %args = testapi::compat_args({cmd => undef}, ['cmd'], @_);
    die('Argument <cmd> missing') unless ($args{cmd});
    $args{ssh_opts} //= $self->ssh_opts() . " -i '" . $self->ssh_key . "'";
    $args{username} //= $self->username();
    $args{timeout} //= SSH_TIMEOUT;
    $args{quiet} //= 1;
    $args{no_quote} //= 0;
    my $rc_only = $args{rc_only} // 0;
    my $timeout = $args{timeout};

    my $cmd = $args{cmd};
    unless ($args{no_quote}) {
        $cmd =~ s/'/'"'"'/g;
        $cmd = "'$cmd'";
    }

    my $ssh_cmd = sprintf('ssh %s "%s@%s" -- %s', $args{ssh_opts}, $args{username}, $self->public_ip, $cmd);
    $ssh_cmd = "timeout $timeout $ssh_cmd" if ($timeout > 0);
    record_info('SSH CMD', $ssh_cmd);

    delete($args{cmd});
    delete($args{no_quote});
    delete($args{ssh_opts});
    delete($args{username});
    delete($args{rc_only});
    if ($args{timeout} == 0) {
        # Run the command and don't wait for it - no output nor returncode here
        script_run($ssh_cmd, %args);
    } elsif ($rc_only) {
        # Increase the hard timeout for script_run, otherwise our 'timeout $args{timeout} ...' has no effect
        $args{timeout} += 2;
        $args{quiet} = 0;
        $args{die_on_timeout} = 1;
        # Run the command and return only the returncode here
        return script_run($ssh_cmd, %args);
    } else {
        # Run the command, wait for it and return the output
        return script_output($ssh_cmd, %args);
    }
}

=head2 retry_ssh_command

    ssh_script_retry(command[, retry => 3][, delay => 10][, timeout => 90][, ssh_opts =>'..'][, username => 'XXX'][, no_quote => 0]);

Run a C<command> via ssh in the given PC instance until it succeeds or
the given number of retries is exhausted and an exception is thrown.
Timeout can be set by C<timeout> or 90 sec by default.
By default, the command is passed in single quotes to SSH.
To avoid quoting use C<<no_quote=>1>>.
With C<<ssh_opts=>'...'>> you can overwrite all default ops which are in
C<<$instance->ssh_opts>>.
Use argument C<username> to specify a different username then
C<<$instance->username()>>.
=cut
sub retry_ssh_command {
    my $self = shift;
    my %args = testapi::compat_args({cmd => undef}, ['cmd'], @_);
    $args{rc_only} = 1;
    $args{timeout} //= 90;    # Timeout before we cancel the command
    my $tries = delete $args{retry} // 3;
    my $delay = delete $args{delay} // 10;
    my $cmd = delete $args{cmd};

    for (my $try = 0; $try < $tries; $try++) {
        my $rc = $self->run_ssh_command(cmd => $cmd, %args);
        return $rc if (defined $rc && $rc == 0);
        sleep($delay);
    }
    die "Waiting for Godot: " . $cmd;
}

=head2 scp

    scp($from, $to, timeout => 90);

Use scp to copy a file from or to this instance. A url starting with
C<remote:> is replaced with the IP from this instance. E.g. a call to copy
the file I</var/log/cloudregister> to I</tmp> looks like:
C<<<$instance->scp('remote:/var/log/cloudregister', '/tmp');>>>
=cut
sub scp {
    my ($self, $from, $to, %args) = @_;
    $args{timeout} //= SSH_TIMEOUT;

    my $url = sprintf('%s@%s:', $self->username, $self->public_ip);
    $from =~ s/^remote:/$url/;
    $to =~ s/^remote:/$url/;

    my $ssh_cmd = sprintf('scp %s -i "%s" "%s" "%s"',
        $self->ssh_opts, $self->ssh_key, $from, $to);

    return script_run($ssh_cmd, %args);
}

=head2 upload_log

    upload_log($filename);

Upload a file from this instance to openqa using L<upload_logs()>.
If the file doesn't exists on the instance, B<no> error is thrown.
=cut
sub upload_log {
    my ($self, $remote_file, %args) = @_;

    my $tmpdir = script_output('mktemp -d');
    my $dest = $tmpdir . '/' . basename($remote_file);
    my $ret = $self->scp('remote:' . $remote_file, $dest);
    upload_logs($dest, %args) if (defined($ret) && $ret == 0);
    assert_script_run("test -d '$tmpdir' && rm -rf '$tmpdir'");
}

=head2 wait_for_guestregister

    wait_for_guestregister([timeout => 300]);

Run command C<systemctl is-active guestregister> on the instance in a loop and
wait till guestregister is ready. If guestregister finish with state failed,
a soft-failure will be recorded.
If guestregister will not finish within C<timeout> seconds, job dies.
In case of BYOS images we checking that service is inactive and quit
Returns the time needed to wait for the guestregister to complete.
=cut
sub wait_for_guestregister
{
    my ($self, %args) = @_;
    $args{timeout} //= 300;
    my $start_time = time();
    my $last_info = 0;

    # Check what version of registercloudguest binary we use
    $self->run_ssh_command(cmd => "sudo rpm -qa cloud-regionsrv-client", proceed_on_failure => 1);

    while (time() - $start_time < $args{timeout}) {
        my $out = $self->run_ssh_command(cmd => 'sudo systemctl is-active guestregister', proceed_on_failure => 1, quiet => 1);
        # guestregister is expected to be inactive because it runs only once
        if ($out eq 'inactive') {
            $self->upload_log('/var/log/cloudregister', log_name => $autotest::current_test->{name} . '-cloudregister.log');
            return time() - $start_time;
        } elsif ($out eq 'failed') {
            $self->upload_log('/var/log/cloudregister', log_name => $autotest::current_test->{name} . '-cloudregister.log');
            $out = $self->run_ssh_command(cmd => 'sudo systemctl status guestregister', proceed_on_failure => 1, quiet => 1);
            record_info("guestregister failed", $out, result => 'fail');
            if (is_azure) {
                record_soft_failure("bsc#1195156");
            } else {
                die("guestregister failed");
            }
            return time() - $start_time;
        } elsif ($out eq 'active') {
            $self->upload_log('/var/log/cloudregister', log_name => $autotest::current_test->{name} . '-cloudregister.log');
            die "guestregister should not be active on BYOS" if (is_byos);
        }

        if (time() - $last_info > 10) {
            record_info('WAIT', 'Wait for guest register: ' . $out);
            $last_info = time();
        }
        sleep 1;
    }
    $self->upload_log('/var/log/cloudregister', log_name => $autotest::current_test->{name} . '-cloudregister.log');
    die('guestregister didn\'t end in expected timeout=' . $args{timeout});
}

=head2 wait_for_ssh

    wait_for_ssh([timeout => 600] [, proceed_on_failure => 0])

Check if the SSH port of the instance is reachable and open.
=cut
sub wait_for_ssh
{
    my ($self, %args) = @_;
    $args{timeout} //= 600;
    $args{proceed_on_failure} //= 0;
    $args{username} //= $self->username();
    my $start_time = time();
    my $check_port = 1;

    # Looping until reaching timeout or passing two conditions :
    # - SSH port 22 is reachable
    # - journalctl got message about reaching one of certain targets
    while ((my $duration = time() - $start_time) < $args{timeout}) {
        if ($check_port) {
            $check_port = 0 if (script_run('nc -vz -w 1 ' . $self->{public_ip} . ' 22', quiet => 1) == 0);
        }
        elsif ($self->run_ssh_command(cmd => 'sudo journalctl -b | grep -E "Reached target (Cloud-init|Default|Main User Target)"', proceed_on_failure => 1, quiet => 1, username => $args{username}) =~ m/Reached target.*/) {
            return $duration;
        }
        sleep 1;
    }

    # Debug output: We have ocasional error in 'journalctl -b' - see poo#96464 - this will be removed soon.
    $self->run_ssh_command(cmd => 'sudo journalctl -b', proceed_on_failure => 1, username => $args{username});

    unless ($args{proceed_on_failure}) {
        my $error_msg;
        if ($check_port) {
            $error_msg = sprintf("Unable to reach SSH port of instance %s with public IP:%s within %d seconds", $self->{instance_id}, $self->{public_ip}, $args{timeout});
        }
        else {
            $error_msg = sprintf("Can not reach systemd target on instance %s with public IP:%s within %d seconds", $self->{instance_id}, $self->{public_ip}, $args{timeout});
        }
        croak($error_msg);
    }

    return;
}

=head2 softreboot

    ($shutdown_time, $bootup_time) = softreboot([timeout => 600]);

Does a softreboot of the instance by running the command C<shutdown -r>.
Return an array of two values, first one is the time till the instance isn't
reachable anymore. The second one is the estimated bootup time.
=cut
sub softreboot
{
    my ($self, %args) = @_;
    $args{timeout} //= 600;
    $args{username} //= $self->username();

    my $duration;

    $self->run_ssh_command(cmd => 'sudo shutdown -r +1');
    # skip the one minute waiting
    sleep 60;
    my $start_time = time();

    # wait till ssh disappear
    while (($duration = time() - $start_time) < $args{timeout}) {
        last unless (defined($self->wait_for_ssh(timeout => 1, proceed_on_failure => 1, username => $args{username})));
    }
    my $shutdown_time = time() - $start_time;
    die("Waiting for system down failed!") unless ($shutdown_time < $args{timeout});
    my $bootup_time = $self->wait_for_ssh(timeout => $args{timeout} - $shutdown_time, username => $args{username});
    return ($shutdown_time, $bootup_time);
}

=head2 stop

    stop();

Stop the instance using the CSP api calls.
=cut
sub stop
{
    my $self = shift;
    $self->provider->stop_instance($self, @_);
}

=head2 start

    start([timeout => ?]);

Start the instance and check SSH connectivity. Return the number of seconds
till the SSH port was available.
=cut
sub start
{
    my ($self, %args) = @_;
    $self->provider->start_instance($self, @_);
    return $self->wait_for_ssh(timeout => $args{timeout});
}

=head2 get_state

    get_state();

Get the status of the instance using the CSP api calls.
=cut
sub get_state
{
    my $self = shift;
    return $self->provider->get_state_from_instance($self, @_);
}

1;
