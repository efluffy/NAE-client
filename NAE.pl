#!/usr/bin/perl

use Digest::MD5 qw(md5_hex);
use LWP::UserAgent;
use HTTP::Cookies;
use JSON qw(decode_json);
use Curses qw(KEY_ENTER KEY_PPAGE KEY_NPAGE KEY_END COLOR_RED KEY_UP KEY_DOWN);
use Curses::UI;
use Curses::UI::Common qw(CUI_TAB);
use Term::ReadKey;
use strict;
use warnings;
use Time::Piece;
use utf8::all;
use HTML::Entities;
use Term::ANSIColor;
no warnings 'uninitialized';

#######################################################################

our $user        = "";
our $pass        = "";
our $char        = "";
our $charName    = "";
our $room        = "";
our $color       = "";
our $botName     = "";
our $passDigest  = md5_hex($pass);
our $cookie      = "./cookie.txt";
our $login_url   = "";
our $data_url    = "";
our $get_url     = "";
our $post_url    = "";
our $whisper_url = "";
our $logfile     = "./logs/" . localtime()->strftime( "%Y-%m-%d") . "-NAE.txt";
my $url_timeout = 10;
our $lastMsg = 0;
our %users;
our $pagePos = 0;
our $dialogCounter = 0;
our @queryList = ('Lobby');
our $activeQuery = 0;
our $mainLog;
our $afk = 0;

#######################################################################

our $ua = LWP::UserAgent->new;
$ua->agent('ErikaClient/1.0 ');
$ua->cookie_jar( HTTP::Cookies->new( file => "$cookie", autosave => 1 ) );
$ua->timeout($url_timeout);
my ( $cols, $rows, $wp, $hp ) = GetTerminalSize();
my $cui = new Curses::UI( -color_support => 1 );
$cui->set_binding( \&eDialog, "\cQ" );
my ( $mainView, $mainWin, $mainEntry, $entryWin, $userWin, $mainUser, $queryWin, $mainQuery );

#######################################################################

sub _connect {
    my %postURLEncoded = (
        'LoginForm[hashpass]' => "$passDigest",
        'LoginForm[username]' => "$user",
        'LoginForm[password]' => ""
    );

    my $resLogin = $ua->post( $login_url, \%postURLEncoded );
    my $resData = $ua->get($data_url);

    if ( $resLogin->is_error() || $resData->is_error() ) {
        $resLogin = $resLogin->status_line;
        $resData  = $resData->status_line;
        die "\n\n\nLogin Error\n\n\n$resLogin\n\n$resData";
    }
}

sub _prune {
    my @logLines = split(/\n/, $mainLog);
    my $linesToSplice = $#logLines - 500;
    shift @logLines for 1..$linesToSplice;
    $mainLog = join('\n', @logLines);
}

sub _sendMsg {
    my $text = shift;
    my $who;
    my $uid;
    $text =~ s/</&lt\;/g;
    $text =~ s/>/&gt\;/g;
    if( $activeQuery != 0 ) {
        if($text =~ m/^(\/query|\/close)/i){ goto OUT; }
        else {
            my $sendTo = $queryList[$activeQuery];
            $text = "/pm $sendTo " . $text;
        }
    }
    OUT:
    if ( $text =~ m/^\/pm/i ) {
        $text =~ s/^\/pm\s*//i;
        foreach my $key ( keys %users ) {
            if ( $text =~ m/^$key.*/i ) {
                $who  = $key;
                $uid  = $users{$key};
                $text = substr( $text, length($key) + 1, length($text) );
                $text =~ s/^\/me/\x{2021}e/;
            }
            last if ( $who ne '' );
        }
        my %pmURLEncoded = (
            'toid'  => "$uid",
            'name'  => "$who",
            'room'  => "$room",
            'color' => "$color",
            'text'  => "$text",
            'char'  => "$char"
        );
        $ua->post( $whisper_url, \%pmURLEncoded );
    }
    elsif ( $text =~ m/^\/query/i ) {
        $text =~ s/^\/query\s*//i;
		if($text eq '') { return; }
        foreach my $key ( keys %users ) {
            if ( $text =~ m/^$key.*/i ) {
                $who  = $key;
            }
            last if ( $who ne '' );
        }
        push(@queryList, $who);
        $activeQuery = $#queryList;
        _updateView();
    }
    elsif ( $text =~ m/^\/close/i ) {
        if ( $activeQuery != 0 ) {
            splice(@queryList, $activeQuery, 1);
            $activeQuery = 0;
            _updateView();
        }
    }
	elsif ( $text =~ m/^\/afk/i) {
		$text =~ s/^\/afk//;
		my %afkEncoded = (
			'lastmsg'		  => $lastMsg,
			'rooms[1]'        => "",
			'rooms[1][status]'  => "a",
			'rooms[1][statmsg]' => "AFK"
		);
		$afk = 1;
		$queryList[0] = "(AFK)Lobby";
		_updateView();
		$ua->post( $get_url, \%afkEncoded );
	}
	elsif ( $text =~ m/^\/back/) {
		$afk = 0;
		$queryList[0] = "Lobby";
		_updateView();
		_updateIdle();	
	}
    else {
        $text =~ s/^\/me/\x{2021}e/;
        my %sendURLEncoded = (
            'room'  => "$room",
            'color' => "$color",
            'text'  => "$text",
            'char'  => "$char"
        );
        $ua->post( $post_url, \%sendURLEncoded );
    }
}

sub _parseMsg {
    my ( $json, $which ) = @_;
    my $name;
    my $toName = $json->{data}->{msg}[$which]{toName};
    my @nameArr = ( split /\|/, $json->{data}->{msg}[$which]{fromName} );
    if ( $nameArr[1] == 0 ) {
        return;
    }
    elsif ( $nameArr[0] eq $nameArr[2] || $nameArr[2] =~ m/.*:.*/ ) {
        $name = $nameArr[2];
    }
    else {
        $name = $nameArr[2] . "(" . $nameArr[0] . ")";
    }
    my $msg  = $json->{data}->{msg}[$which]{text};
    my $time = localtime( $json->{data}->{msg}[$which]{time} )->strftime('%T');
    if ( $msg ne '' ) {
        if ( $toName eq $charName ) {
			if ( $msg =~ m/^\x{2021}e.*/ ) {
                $name = "#*" . $name . " to $charName: ";
            }
            else {
                $name = "#" . $name . " to $charName: ";
            }
        }
        elsif ( $toName ne '' ) {
            if ( $msg =~ m/^\x{2021}e.*/ ) {
                $name = "#*" . $name . " to $toName: ";
            }
            else {
                $name = "#" . $name . " to $toName: ";
            }
        }
        else {
            if ( $msg =~ m/^\x{2021}e.*/ ) {
                $name = "*" . $name . " ";
            }
            elsif ( $msg =~ m/^\x{2021}[abzdlio].*/ ) {
                $name = "%" . $name . ": ";
            }
            else {
                $name = "<" . $name . "> ";
            }
        }
        $msg =~ s/^\x{2021}..//;
        if($msg =~ m/.*erika.*/i){
            $name = "*** " . $name;
            open LOG2, ">>", "./eri-callout.txt" || die $!;
            print LOG2 "[" . $time . "] " . $name . " " . $msg . "\n";
            close LOG2;
        }
        my $out = decode_entities( "[" . $time . "] " . $name . $msg . "\n" );
        open LOG, ">>", "$logfile" || die $!;
        print LOG $out;
        close LOG;
        return $out;
    }
}

sub _getMsgs {
    my $data;
    my $msgString;
    my $json_string;
    if ( $lastMsg == 0 ) {
        my %getEncoded = (
            'lastmsg'          => "0",
            'rooms[1]'         => "",
            'rooms[1][chars]'  => $char,
            'roominfo'         => "true",
            'rooms[1][status]' => "o",
            'history'          => "1"
        );
        $json_string = ( $ua->post( $get_url, \%getEncoded ) )->content();
        if($json_string =~ m/(Can't connect|read timeout)/) {
#            if( $dialogCounter == 0 ) { dcDialog(); $dialogCounter++; }
        }
        else {
            my $json_object =
              decode_json( ( $ua->post( $get_url, \%getEncoded ) )->content() );

            for ( my $i = 29 ; $i >= 0 ; $i-- ) {
                $msgString = $msgString . _parseMsg( $json_object, $i );
            }

            $lastMsg = $json_object->{data}->{msg}[0]{id};
        }
    }

    else {
        my %updateEncoded = (
            'lastmsg'  => $lastMsg,
            'rooms[1]' => ""
        );
        $json_string = ( $ua->post( $get_url, \%updateEncoded ) )->content();
        if($json_string =~ m/(Can't connect|read timeout)/) {
#            if( $dialogCounter == 0 ) { dcDialog(); $dialogCounter++; }
        }
        else {
            my $json_object =
              decode_json($json_string);

            if ( $json_object->{data}->{msg}[0]{id} != 0 ) {

                for (
                    my $i =
                    ( ( $json_object->{data}->{msg}[0]{id} - $lastMsg ) - 1 ) ;
                    $i >= 0 ;
                    $i--
                  )
                {
                    $msgString = $msgString . _parseMsg( $json_object, $i );
                }

                $lastMsg = $json_object->{data}->{msg}[0]{id};
            }

            else {
                return;
            }
        }
    }
    return $msgString;
}

sub _updateIdle {
    my %updateEncoded = (
		'lastmsg' 		  => $lastMsg,
        'rooms[1]'        => "",
        'rooms[1][status]'  => "o",
		'rooms[1][statmsg]' => ""
    );

    $ua->post( $get_url, \%updateEncoded );
}

sub _getUsers {
    %users = ();
    my @userArr;
    my %usersEncoded = (
        'lastmsg'  => $lastMsg,
        'rooms[1]' => "",
        'users'    => "true"
    );
    my $json_string = ( $ua->post( $get_url, \%usersEncoded ) )->content();
    if($json_string =~ m/(Can't connect|read timeout)/) {
#		if( $dialogCounter == 0 ) { dcDialog(); $dialogCounter++; }
    }
    else {
	my $json_object = decode_json( $json_string );
        foreach my $ref ( @{ $json_object->{data}->{users} } ) {
            $users{ ( split /\|/, $ref->{name} )[0] } = $ref->{id};
            if ( $ref->{status} eq "i" || $ref->{status} eq "x" || $ref->{status} eq "a" ) {
                push( @userArr, "~" . ( split /\|/, $ref->{name} )[0] );
            }
            else {
                push( @userArr, ( split /\|/, $ref->{name} )[0] );
            }

        }
        @userArr = sort(@userArr);
        return join( "\n", @userArr );
    }
}

sub eDialog {
    my $return = $cui->dialog(
        -message => "Are you sure?",
        -title   => "Really quit?",
        -buttons => [ 'yes', 'no' ]
    );
    exit(0) if $return;
}

sub dcDialog {
    my $return = $cui->dialog(
        -message => "Connection Interruption!",
        -title => "Error!",
		-buttons => [ 'yes', 'no' ]
    );
	if( $return ) { $dialogCounter--; }
}

#######################################################################

$mainWin = $cui->add(
    'viewWin', 'Window',
    -border => 1,
    -height => ( $rows - 4 ),
    -width  => ( $cols - 20 ),
    -bfg    => 'green'
);

$mainView = $mainWin->add(
    "viewWid", "TextViewer",
    -wrapping   => 1,
    -vscrollbar => 'right'
);

$userWin = $cui->add(
    'userWin', 'Window',
    -border => 1,
    -height => ( $rows - 4 ),
    -x      => ( $cols - 20 ),
    -bfg    => 'green'
);

$mainUser = $userWin->add( "userWid", "TextViewer", -wrapping => 0, );

$entryWin = $cui->add(
    'entryWin', 'Window',
    -border => 1,
    -y      => ( $rows - 3 ),
    -height => 1,
    -bfg    => 1
);

$mainEntry = $entryWin->add( "entryWid", "TextEntry" );

$queryWin = $cui->add(
    'queryWin', 'Window',
    -border => 0,
    -y      => ( $rows - 4 ),
    -height => 1,
    -fg    => 'grey'
);

$mainQuery = $queryWin->add( "queryWid", "TextViewer" );

$mainEntry->set_binding(
    sub {
        _sendMsg( $mainEntry->text() );
        _updateView();
        $mainView->cursor_to_end();
        $mainView->draw;
        $mainEntry->text("");
    },
    KEY_ENTER
);

sub _updateView {
    $mainLog = $mainLog . _getMsgs();
    my $numLines = scalar split /\n/ for $mainLog;
    if( $numLines > 500 ) { _prune(); }
    if($activeQuery == 0) {
        $mainView->text( $mainLog );
    }
    else {
        my $viewTextBuilder;
        my $queryName = $queryList[$activeQuery];
        my @tempLines = split(/\n/, $mainLog);
        $viewTextBuilder = "";
        foreach my $line (@tempLines) {
            if($line =~ m/^.*(#(\*)?$queryName to $charName|.*#(\*)?$charName to $queryName).*/) {
                $viewTextBuilder = $viewTextBuilder . $line . "\n";
            }
        }
        $mainView->text( $viewTextBuilder );
    }
    if( $pagePos == 0 ) { $mainView->cursor_to_end(); }
    $mainView->draw;
    my $queryStringBuilder;
    for my $i (0..$#queryList) {
        if($activeQuery == $i) { $queryStringBuilder = $queryStringBuilder . "->" . $queryList[$i] . "<-"; }
        else { $queryStringBuilder = $queryStringBuilder . " <" . $queryList[$i] . "> "; }
    }
    $mainQuery->text( $queryStringBuilder );
    $mainQuery->draw;
}

$cui->set_timer(
    'update',
    sub {
        _updateView();
    },
    3
);

$cui->set_timer(
    'userUpdate',
    sub {
        $mainUser->text( _getUsers() );
        $mainUser->draw;
    },
    8
);

$cui->set_timer(
    'updateIdle',
    sub {
        if( $afk == 0 ) { _updateIdle(); }
    },
    300
);

$mainEntry->set_binding(
    sub {
        $mainView->focus();
        $mainView->cursor_pageup();
        $mainEntry->focus();
		$pagePos++;
    },
    KEY_PPAGE
);

$mainEntry->set_binding(
    sub {
        if( $activeQuery < $#queryList ) { $activeQuery++; _updateView(); }
    },
    KEY_UP
);

$mainEntry->set_binding(
    sub {
        if( $activeQuery > 0 ) { $activeQuery--; _updateView(); }
    },
    KEY_DOWN
);

$mainEntry->set_binding(
    sub {
        my $searchFor = ( split / /, $mainEntry->text() )[-1];
        my $text = $mainEntry->text();
        foreach my $key ( keys %users ) {
            if ( $key =~ m/^$searchFor.*/i ) {
                if ( $text eq $searchFor ) {
                    $mainEntry->text( $key . ": " );
                }
                else {
                    $text = substr( $text, 0, ( length($searchFor) * -1 ) - 1 );
                    $mainEntry->text( $text . " " . $key . " " );
                }
                if($pagePos == 0) { $mainEntry->cursor_to_end(); }
                last;
            }
        }
    },
    CUI_TAB()
);

$mainEntry->set_binding(
    sub {
        $mainView->focus();
        $mainView->cursor_pagedown();
        $mainEntry->focus();
		if( $pagePos > 0 ) { $pagePos--; }
    },
    KEY_NPAGE
);

_connect();
$mainLog = _getMsgs();
$mainView->text( $mainLog );
$mainEntry->focus();
$cui->mainloop();
