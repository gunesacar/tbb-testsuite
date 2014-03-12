package TBBTestSuite::Tests;

use warnings;
use strict;
use FindBin;
use Cwd qw(getcwd);
use File::Spec;
use File::Temp;
use File::Slurp;
use LWP::UserAgent;
use Digest::SHA qw(sha256_hex);
use IO::CaptureOutput qw(capture_exec);
use IO::Socket::INET;
use JSON;
use File::Copy;
use Image::Magick;
use YAML;
use TBBTestSuite::Common qw(exit_error);
use TBBTestSuite::Options qw($options);

my %tests = (
    tor_bootstrap => { type => 'tor_bootstrap' },
    check_screenshot => { type => 'mozmill' },
    check => { type => 'selenium' },
);
%tests = map { $_ => { name => $_, %{$tests{$_}} } } keys %tests;

sub get_tbbfile {
    my ($tbbinfos, $tbbfile) = @_;
    if ($tbbfile =~ m/^https?:\/\//) {
        my (undef, undef, $file) = File::Spec->splitpath($tbbfile);
        my $output = $options->{'download-dir'} ?
                "$options->{'download-dir'}/$file" : "$tbbinfos->{tmpdir}/$file";
        return $output if -f $output;
        print "Downloading $tbbfile\n";
        my $ua = LWP::UserAgent->new;
        my $resp = $ua->get($tbbfile, ':content_file' => $output);
        exit_error "Error downloading $tbbfile:\n" . $resp->status_line
                unless $resp->is_success;
        return $output;
    }
    exit_error "File $tbbfile does not exist" unless -f $tbbfile;
    return $tbbfile;
}

sub tbb_filename_infos {
    my ($tbbfile) = @_;
    my (undef, undef, $file) = File::Spec->splitpath($tbbfile);
    my %res = (filename => $file);
    if ($file =~ m/^tor-browser-linux(..)-([^_]+)_(.+)\.tar\.xz$/) {
        @res{qw(type os version language)} = ('tbbfile', 'Linux', $2, $3);
        $res{arch} = $1 eq '64' ? 'x86_64' : 'x86';
    } elsif ($file =~ m/^torbrowser-install-([^_]+)_(.+)\.exe$/) {
        @res{qw(type os arch version language)} =
                ('tbbfile', 'Windows', 'x86', $1, $2);
    } elsif ($file =~ m/^TorBrowserBundle-(.+)-osx32_(.+)\.zip$/) {
        @res{qw(type os arch version language)} =
                ('tbbfile', 'MacOSX', 'x86', $1, $2);
    } elsif ($file eq 'sha256sums.txt') {
        $res{type} = 'sha256sum';
    } else {
        $res{type} = 'Unknown';
    }
    return \%res;
}

sub extract_tbb {
    my ($tbbinfos, $tbbfile) = @_;
    exit_error "Can't open file $tbbfile" unless -f $tbbfile;
    $tbbfile = File::Spec->rel2abs($tbbfile);
    my $tmpdir = $tbbinfos->{tmpdir};
    chdir $tmpdir;
    system('tar', 'xf', $tbbfile);
    $tbbinfos->{tbbdir} = "$tmpdir/tor-browser_$tbbinfos->{language}";
}

sub setup_tbb {
    $ENV{TOR_SKIP_LAUNCH} = 1;
}

sub monitor_bootstrap {
    my ($tbbinfos, $control_passwd) = @_;
    sleep 10;
    my $sock = new IO::Socket::INET(
        PeerAddr => 'localhost',
        PeerPort => $options->{'tor-control-port'},
        Proto => 'tcp',
    );
    exit_error "Error connecting to control port: $!\n" unless $sock;
    print $sock 'AUTHENTICATE "', $control_passwd, "\"\n";
    my $r = <$sock>;
    exit_error "Authentication error: $r" unless $r =~ m/^250 OK/;
    my $i = 0;
    while (1) {
        print $sock "GETINFO status/bootstrap-phase\n";
        $r = <$sock>;
        print $r;
        last if $r =~ m/^250-status\/bootstrap-phase.* TAG=done/;
        sleep 1;
        $i++;
        if ($i > 300) {
            $tbbinfos->{tests}{tor_bootstrap}{results}{success} = 0;
            return 0;
        }
    }
    print "Bootstraping done\n";
    $tbbinfos->{tests}{tor_bootstrap}{results}{success} = 1;
    return 3;
}

# TODO: In the future, we should start tor using tor-launcher
sub start_tor {
    my ($tbbinfos) = @_;
    return unless $options->{starttor};
    my $control_passwd = map { ('a'..'z', 'A'..'Z', 0..9)[rand 62] } 0..8;
    my $cwd = getcwd;
    $ENV{LD_LIBRARY_PATH} = "$cwd/Tor/";
    $ENV{TOR_SOCKS_PORT} = $options->{'tor-socks-port'};
    $ENV{TOR_CONTROL_PORT} = $options->{'tor-control-port'};
    $ENV{TOR_CONTROL_HOST} = '127.0.0.1';
    $ENV{TOR_CONTROL_COOKIE_AUTH_FILE} = "$cwd/Data/Tor/control_auth_cookie";
    my ($hashed_password, undef, $success) =
        capture_exec("$cwd/Tor/tor", '--quiet', '--hash-password', $control_passwd);
    exit_error "Error running tor --hash-password" unless $success;
    chomp $hashed_password;
    my @torrc = read_file('Data/Tor/torrc-defaults');
    foreach (@torrc) {
        s/^ControlPort .*/ControlPort $options->{'tor-control-port'}/;
        s/^SocksPort .*/SocksPort $options->{'tor-socks-port'}/;
    }
    write_file('Data/Tor/torrc-defaults', @torrc);
    my @cmd = ("$cwd/Tor/tor", '--defaults-torrc', "$cwd/Data/Tor/torrc-defaults",
        '-f', "$cwd/Data/Tor/torrc", 'DataDirectory', "$cwd/Data/Tor",
        'GeoIPFile', "$cwd/Data/Tor/geoip", '__OwningControllerProcess', $$,
        'HashedControlPassword', $hashed_password);
    $tbbinfos->{torpid} = fork;
    if ($tbbinfos->{torpid} == 0) {
        my $logfile = "$tbbinfos->{'results-dir'}/tor.log";
        open(STDOUT, '>', $logfile);
        open(STDERR, '>', $logfile);
        exec @cmd;
    }
    return monitor_bootstrap($tbbinfos, $control_passwd);
}

sub stop_tor {
    my ($tbbinfos) = @_;
    return unless $options->{starttor};
    kill 9, $tbbinfos->{torpid};
}

sub screenshot_thumbnail {
    my ($dir, $name) = @_;
    my $image = Image::Magick->new;
    $image->Read("$dir/$name");
    $image->Scale(geometry => '600x600');
    $image->Write("$dir/t-$name");
}

sub xvfb_run {
    my ($test) = @_;
    return () unless $options->{xvfb};
    my $resolution = $test->{resolution} ? $test->{resolution}
                                         : $options->{resolution};
    return ('xvfb-run', '-s', "-screen 0 ${resolution}x24");
}

sub mozmill_run {
    my ($tbbinfos, $test) = @_;
    return unless $options->{mozmill};
    $test->{screenshots} = [];
    my $screenshots_tmp = File::Temp::newdir;
    $ENV{'MOZMILL_SCREENSHOTS'} = $screenshots_tmp;
    my $results_file = "$tbbinfos->{'results-dir'}/$test->{name}.json";
    system(xvfb_run($test), "$options->{virtualenv}/bin/mozmill", '-b',
        "$tbbinfos->{tbbdir}/Browser/firefox", '-p',
        "$tbbinfos->{tbbdir}/Data/Browser/profile.default", '-t',
        "$FindBin::Bin/mozmill-tests/tbb-tests/$test->{name}.js",
        '--report', "file://$results_file");
    my $i = 0;
    for my $screenshot_file (glob "$screenshots_tmp/*.png") {
        move($screenshot_file, "$tbbinfos->{'results-dir'}/$test->{name}-$i.png");
        screenshot_thumbnail($tbbinfos->{'results-dir'}, "$test->{name}-$i.png");
        push @{$test->{screenshots}}, "$test->{name}-$i.png";
        $i++;
    }
    $test->{results} = decode_json(read_file($results_file));
    $test->{results}{success} = !$test->{results}{results}->[0]->{failed};
}

sub selenium_run {
    my ($tbbinfos, $test) = @_;
    return unless $options->{selenium};
    my $result_file = $ENV{SELENIUM_TEST_RESULT_FILE} =
        "$tbbinfos->{'results-dir'}/$test->{name}.json";
    system(xvfb_run($test), "$options->{virtualenv}/bin/python",
        "$FindBin::Bin/selenium-tests/run_test", $test->{name});
    $test->{results} = decode_json(read_file($result_file));
}

sub run_tests {
    my ($tbbinfos) = @_;
    my %types = (
        mozmill  => \&mozmill_run,
        selenium => \&selenium_run,
    );
    my $tests = $tbbinfos->{tests};
    foreach my $test (keys %$tests) {
        $types{$tests->{$test}{type}}->($tbbinfos, $tests->{$test})
                if $types{$tests->{$test}{type}};
    }
}

sub is_success {
    my ($tests) = @_;
    foreach my $test (keys %$tests) {
        if ($tests->{$test}{results} && !$tests->{$test}{results}{success}) {
            return 0;
        }
    }
    return 1;
}

sub matching_tbbfile {
    my $o = tbb_filename_infos($_[0]);
    return $o->{type} eq 'tbbfile' && $o->{os} eq $options->{os}
        && $o->{arch} eq $options->{arch};
}

sub check_gpgsig {
    my ($file) = @_;
    my $keyring = $options->{keyring} =~ m/^\// ? $options->{keyring}
        : "$FindBin::Bin/keyring/$options->{keyring}";
    return system('gpg', '--no-default-keyring', '--keyring', $keyring,
        '--verify', '--', $file) == 0;
}

sub test_sha {
    my ($report, $shafile) = @_;
    my $content;
    if ($shafile =~ m/^https?:\/\//) {
        my $ua = LWP::UserAgent->new;
        my $resp = $ua->get($shafile);
        exit_error "Error downloading $shafile:\n" . $resp->status_line
                unless $resp->is_success;
        $content = $resp->decoded_content;
        if ($options->{gpgcheck}) {
            $resp = $ua->get("$shafile.asc");
            exit_error "Error downloading $shafile.asc:\n" . $resp->status_line
                unless $resp->is_success;
            my $tmpdir = File::Temp::newdir;
            write_file("$tmpdir/sha256sum.txt", $content);
            write_file("$tmpdir/sha256sum.txt.asc", $resp->decoded_content);
            exit_error "Error checking gpg signature of $shafile"
                unless check_gpgsig("$tmpdir/sha256sum.txt.asc");
        }
    } else {
        $content = read_file($shafile);
    }
    my (undef, $dir) = File::Spec->splitpath($shafile);
    my @files = map { [ reverse split /  /, $_ ] } split /\n/, $content;
    @files = grep { matching_tbbfile($_->[0]) } @files;
    foreach my $file (@files) {
        test_tbb($report, "$dir/$file->[0]", $file->[1]);
    }
}

sub test_tbb {
    my ($report, $tbbfile, $sha256sum) = @_;
    my $oldcwd = getcwd;
    my $tbbinfos = tbb_filename_infos($tbbfile);
    return test_sha($report, $tbbfile) if $tbbinfos->{type} eq 'sha256sum';
    my $tmpdir = File::Temp::newdir;
    $tbbinfos->{tmpdir} = $tmpdir->dirname;
    $tbbfile = get_tbbfile($tbbinfos, $tbbfile);
    if ($sha256sum && $sha256sum ne sha256_hex(read_file($tbbfile))) {
        exit_error "Wrong sha256sum for $tbbfile";
    }
    $tbbinfos->{sha256sum} = $sha256sum ? $sha256sum
                                        : sha256_hex(read_file($tbbfile));
    $tbbinfos->{tests} = { map { $_ => { %{$tests{$_}} } } keys %tests };
    $tbbinfos->{'results-dir'} =
        "$options->{'report-dir'}/results-$tbbinfos->{filename}";
    mkdir $tbbinfos->{'results-dir'};
    extract_tbb($tbbinfos, $tbbfile);
    chdir $tbbinfos->{tbbdir} || exit_error "Can't enter directory $tbbinfos->{tbbdir}";
    $ENV{TBB_BIN} = "$tbbinfos->{tbbdir}/Browser/firefox";
    $ENV{TBB_PROFILE} = "$tbbinfos->{tbbdir}/Data/Browser/profile.default";
    if (start_tor($tbbinfos)) {
        setup_tbb;
        run_tests($tbbinfos);
        stop_tor($tbbinfos);
    }
    chdir $oldcwd;
    $tbbinfos->{success} = is_success($tbbinfos->{tests});
    $report->{tbbfiles}{$tbbinfos->{filename}} = $tbbinfos;
}

1;
