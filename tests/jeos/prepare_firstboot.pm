# SUSE's openQA tests
#
# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: FSFAP

# Summary: Enable jeos-firstboot as required by openQA testsuite
# Maintainer: Guillaume GARDET <guillaume@opensuse.org>

use strict;
use warnings;
use base "opensusebasetest";
use testapi;
use utils 'zypper_call';
use version_utils 'is_leap';
use Utils::Backends;

sub run {
    my ($self) = @_;

    my $default_password = 'linux';
    my $distripassword = $testapi::password;
    my $reboot_for_jeos_firstboot = 1;

    my $is_generalhw_via_ssh = is_generalhw && !defined(get_var('GENERAL_HW_VNC_IP'));

    if ($is_generalhw_via_ssh) {
        # Run jeos-firstboot manually and do not reboot as we use SSH
        $reboot_for_jeos_firstboot = 0;

        # Handle default credentials for ssh login
        $testapi::password = $default_password;
        # 'root-ssh' console will wait for SUT to be reachable from ssh
        select_console('root-ssh');
    }
    else {
        # Login with default credentials (root:linux)
        assert_screen('linux-login', 300);
        enter_cmd("root", wait_still_screen => 5);
        enter_cmd("$default_password", wait_still_screen => 5);
    }

    # Install jeos-firstboot, when needed
    zypper_call('in jeos-firstboot') if is_leap;

    if ($is_generalhw_via_ssh) {
        # Do not set network down as we are connected through ssh!
        my $filetoedit = is_leap('<=15.2') ? '/usr/lib/jeos-firstboot' : '/usr/share/jeos-firstboot/jeos-firstboot-dialogs';
        assert_script_run("sed -i 's/ip link set down /# ip link set down/g' $filetoedit");
    }
    # Remove current root password
    assert_script_run("sed -i 's/^root:[^:]*:/root:*:/' /etc/shadow", 600);

    # Restore expected password, to be used by jeos-firstboot
    $testapi::password = $distripassword;

    if ($reboot_for_jeos_firstboot) {
        # Ensure YaST2-Firstboot is disabled, and enable jeos-firstboot in openQA
        assert_script_run("systemctl disable YaST2-Firstboot") if is_leap('<15.2');
        assert_script_run("systemctl enable jeos-firstboot");

        # When YaST2-Firstboot is not installed, /var/lib/YaST2 does not exist, so create it
        assert_script_run("mkdir -p /var/lib/YaST2") if !is_leap('<15.2');
        # Trigger *-firstboot at next boot
        assert_script_run("touch /var/lib/YaST2/reconfig_system");

        enter_cmd("reboot");
    }
    else {
        enter_cmd(is_leap('<=15.2') ? "/usr/lib/jeos-firstboot\n" : "jeos-firstboot");
    }
}

1;
