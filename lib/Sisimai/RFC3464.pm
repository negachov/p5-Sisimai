package Sisimai::RFC3464;
use feature ':5.10';
use strict;
use warnings;
use Sisimai::MTA;
use Sisimai::RFC5322;

# http://tools.ietf.org/html/rfc3464
my $Re0 = {
    'from'        => qr/\b(?:postmaster|mailer-daemon|root)[@]/i,
    'return-path' => qr/(?:[<][>]|mailer-daemon)/i,
    'subject'     => qr{(?>
         delivery[ ](?:failed|failure|report)
        |failure[ ]notice
        |mail[ ](?:delivery|error)
        |non[-]delivery
        |returned[ ]mail
        |undeliverable[ ]mail
        |Warning:[ ]
        )
    }xi,
};

my $Re1 = {
    'begin'  => qr{\A(?>
         Content-Type:[ ]*(?:
              message/delivery-status
             |message/disposition-notification
             |text/plain;[ ]charset=
             )
        |The[ ]original[ ]message[ ]was[ ]received[ ]at[ ]
        |This[ ]report[ ]relates[ ]to[ ]your[ ]message
        |Your[ ]message[ ]was[ ]not[ ]delivered[ ]to[ ]the[ ]following[ ]recipients
        )
    }xi,
    'endof'  => qr/\A__END_OF_EMAIL_MESSAGE__\z/,
    'rfc822' => qr{\A(?>
         Content-Type:[ ]*(?:message/rfc822|text/rfc822-headers)
        |Return-Path:[ ]*[<].+[>]\z
        )\z
    }xi,
    'error'  => qr/\A(?:[45]\d\d[ \t]+|[<][^@]+[@][^@]+[>]:?[ \t]+)/i,
    'command'=> qr/[ ](RCPT|MAIL|DATA)[ ]+command\b/,
};

my $Indicators = Sisimai::MTA->INDICATORS;
my $LongFields = Sisimai::RFC5322->LONGFIELDS;
my $RFC822Head = Sisimai::RFC5322->HEADERFIELDS;

sub description { 'Fallback Module for MTAs' };
sub smtpagent   { 'RFC3464' };
sub pattern     { return $Re0 }

sub scan {
    # Detect an error for RFC3464
    # @param         [Hash] mhead       Message header of a bounce email
    # @options mhead [String] from      From header
    # @options mhead [String] date      Date header
    # @options mhead [String] subject   Subject header
    # @options mhead [Array]  received  Received headers
    # @options mhead [String] others    Other required headers
    # @param         [String] mbody     Message body of a bounce email
    # @return        [Hash, Undef]      Bounce data list and message/rfc822 part
    #                                   or Undef if it failed to parse or the
    #                                   arguments are missing
    my $class = shift;
    my $mhead = shift // return undef;
    my $mbody = shift // return undef;
    my $match = 0;

    return undef unless keys %$mhead;
    return undef unless ref $mbody eq 'SCALAR';

    require Sisimai::MDA;
    require Sisimai::Address;

    my $dscontents = []; push @$dscontents, Sisimai::MTA->DELIVERYSTATUS;
    my @hasdivided = split( "\n", $$mbody );
    my $scannedset = Sisimai::MDA->scan( $mhead, $mbody );
    my $rfc822next = { 'from' => 0, 'to' => 0, 'subject' => 0 };
    my $rfc822part = '';    # (String) message/rfc822-headers part
    my $previousfn = '';    # (String) Previous field name
    my $readcursor = 0;     # (Integer) Points the current cursor position
    my $recipients = 0;     # (Integer) The number of 'Final-Recipient' header
    my $connheader = {
        'date'    => '',    # The value of Arrival-Date header
        'rhost'   => '',    # The value of Reporting-MTA header
        'lhost'   => '',    # The value of Received-From-MTA header
    };

    my $v = undef;
    my $p = '';

    for my $e ( @hasdivided ) {
        # Read each line between $Re1->{'begin'} and $Re1->{'rfc822'}.
        unless( $readcursor ) {
            # Beginning of the bounce message or delivery status part
            if( $e =~ $Re1->{'begin'} ) {
                $readcursor |= $Indicators->{'deliverystatus'};
                next;
            }
        }

        unless( $readcursor & $Indicators->{'message-rfc822'} ) {
            # Beginning of the original message part
            if( $e =~ $Re1->{'rfc822'} ) {
                $readcursor |= $Indicators->{'message-rfc822'};
                next;
            }
        }

        if( $readcursor & $Indicators->{'message-rfc822'} ) {
            # After "message/rfc822"
            if( $e =~ m/\A([-0-9A-Za-z]+?)[:][ ]*(.+)\z/ ) {
                # Get required headers only
                my $lhs = lc $1;
                $previousfn = '';
                next unless exists $RFC822Head->{ $lhs };

                $previousfn  = $lhs;
                $rfc822part .= $e."\n";

            } elsif( $e =~ m/\A[ \t]+/ ) {
                # Continued line from the previous line
                next if $rfc822next->{ $previousfn };
                $rfc822part .= $e."\n" if exists $LongFields->{ $previousfn };

            } else {
                # Check the end of headers in rfc822 part
                next unless exists $LongFields->{ $previousfn };
                next if length $e;
                $rfc822next->{ $previousfn } = 1;
            }

        } else {
            # Before "message/rfc822"
            next unless $readcursor & $Indicators->{'deliverystatus'};
            next unless length $e;

            $v = $dscontents->[ -1 ];
            if( $e =~ m/\A(?:[Ff]inal|[Oo]riginal)-[Rr]ecipient:[ ]*(?:RFC|rfc)822;[ ]*([^ ]+)\z/ ||
                $e =~ m/\A(?:[Ff]inal|[Oo]riginal)-[Rr]ecipient:[ ]*([^ ]+)\z/ ) {
                # 2.3.2 Final-Recipient field
                #   The Final-Recipient field indicates the recipient for which this set
                #   of per-recipient fields applies.  This field MUST be present in each
                #   set of per-recipient data.
                #   The syntax of the field is as follows:
                #
                #       final-recipient-field =
                #           "Final-Recipient" ":" address-type ";" generic-address
                #
                # 2.3.1 Original-Recipient field
                #   The Original-Recipient field indicates the original recipient address
                #   as specified by the sender of the message for which the DSN is being
                #   issued.
                # 
                #       original-recipient-field =
                #           "Original-Recipient" ":" address-type ";" generic-address
                #
                #       generic-address = *text
                my $x = $v->{'recipienet'} || '';
                my $y = Sisimai::Address->s3s4( $1 );

                if( length $x && $x ne $y ) {
                    # There are multiple recipient addresses in the message body.
                    push @$dscontents, Sisimai::MTA->DELIVERYSTATUS;
                    $v = $dscontents->[ -1 ];
                }
                $v->{'recipient'} = $y;
                $recipients++;

            } elsif( $e =~ m/\A[Xx]-[Aa]ctual-[Rr]ecipient:[ ]*(?:RFC|rfc)822;[ ]*([^ ]+)\z/ ) {
                # X-Actual-Recipient: 
                if( $1 =~ m/[ \t]+/ ) {
                    # X-Actual-Recipient: RFC822; |IFS=' ' && exec procmail -f- || exit 75 ...

                } else {
                    # X-Actual-Recipient: rfc822; kijitora@neko.example.jp
                    $v->{'alias'} = $1;
                }

            } elsif( $e =~ m/\A[Aa]ction:[ ]*(.+)\z/ ) {
                # 2.3.3 Action field
                #   The Action field indicates the action performed by the Reporting-MTA
                #   as a result of its attempt to deliver the message to this recipient
                #   address.  This field MUST be present for each recipient named in the
                #   DSN.
                #   The syntax for the action-field is:
                #
                #       action-field = "Action" ":" action-value
                #       action-value =
                #           "failed" / "delayed" / "delivered" / "relayed" / "expanded"
                #
                #   The action-value may be spelled in any combination of upper and lower
                #   case characters.
                $v->{'action'} = lc $1;

                if( $v->{'action'} =~ m/\A([^ ]+)[ ]/ ) {
                    # failed (bad destination mailbox address)
                    $v->{'action'} = $1;
                }

            } elsif( $e =~ m/\A[Ss]tatus:[ ]*(\d[.]\d+[.]\d+)/ ) {
                # 2.3.4 Status field
                #   The per-recipient Status field contains a transport-independent
                #   status code that indicates the delivery status of the message to that
                #   recipient.  This field MUST be present for each delivery attempt
                #   which is described by a DSN.
                #
                #   The syntax of the status field is:
                #
                #       status-field = "Status" ":" status-code
                #       status-code = DIGIT "." 1*3DIGIT "." 1*3DIGIT
                $v->{'status'} = $1;

            } elsif( $e =~ m/\A[Ss]tatus:[ ]*(\d+[ ]+.+)\z/ ) {
                # Status: 553 Exceeded maximum inbound message size
                $v->{'alterrors'} = $1;

            } elsif( $e =~ m/\A[Rr]emote-MTA:[ ]*(?:DNS|dns);[ ]*(.+)\z/ ) {
                # 2.3.5 Remote-MTA field
                #   The value associated with the Remote-MTA DSN field is a printable
                #   ASCII representation of the name of the "remote" MTA that reported
                #   delivery status to the "reporting" MTA.
                #
                #       remote-mta-field = "Remote-MTA" ":" mta-name-type ";" mta-name
                #
                #   NOTE: The Remote-MTA field preserves the "while talking to"
                #   information that was provided in some pre-existing nondelivery
                #   reports.
                #
                #   This field is optional.  It MUST NOT be included if no remote MTA was
                #   involved in the attempted delivery of the message to that recipient.
                $v->{'rhost'} = lc $1;

            } elsif( $e =~ m/\A[Ll]ast-[Aa]ttempt-[Dd]ate:[ ]*(.+)\z/ ) {
                # 2.3.7 Last-Attempt-Date field
                #   The Last-Attempt-Date field gives the date and time of the last
                #   attempt to relay, gateway, or deliver the message (whether successful
                #   or unsuccessful) by the Reporting MTA.  This is not necessarily the
                #   same as the value of the Date field from the header of the message
                #   used to transmit this delivery status notification: In cases where
                #   the DSN was generated by a gateway, the Date field in the message
                #   header contains the time the DSN was sent by the gateway and the DSN
                #   Last-Attempt-Date field contains the time the last delivery attempt
                #   occurred.
                #
                #       last-attempt-date-field = "Last-Attempt-Date" ":" date-time
                $v->{'date'} = $1;

            } else {

                if( $e =~ m/\A[Dd]iagnostic-[Cc]ode:[ ]*(.+?);[ ]*(.+)\z/ ) {
                    # 2.3.6 Diagnostic-Code field
                    #   For a "failed" or "delayed" recipient, the Diagnostic-Code DSN field
                    #   contains the actual diagnostic code issued by the mail transport.
                    #   Since such codes vary from one mail transport to another, the
                    #   diagnostic-type sub-field is needed to specify which type of
                    #   diagnostic code is represented.
                    #
                    #       diagnostic-code-field =
                    #           "Diagnostic-Code" ":" diagnostic-type ";" *text
                    $v->{'spec'} = uc $1;
                    $v->{'diagnosis'} = $2;

                } elsif( $e =~ m/\A[Dd]iagnostic-[Cc]ode:[ ]*(.+)\z/ ) {
                    # No value of "diagnostic-type"
                    # Diagnostic-Code: 554 ...
                    $v->{'diagnosis'} = $1;

                } elsif( $p =~ m/\A[Dd]iagnostic-[Cc]ode:[ ]*/ && $e =~ m/\A[ \t]+(.+)\z/ ) {
                    # Continued line of the value of Diagnostic-Code header
                    $v->{'diagnosis'} .= ' '.$1;
                    $e = 'Diagnostic-Code: '.$e;

                } else {
                    if( $e =~ m/\A[Rr]eporting-MTA:[ ]*(?:DNS|dns);[ ]*(.+)\z/ ) {
                        # 2.2.2 The Reporting-MTA DSN field
                        #
                        #       reporting-mta-field =
                        #           "Reporting-MTA" ":" mta-name-type ";" mta-name
                        #       mta-name = *text
                        #
                        #   The Reporting-MTA field is defined as follows:
                        # 
                        #   A DSN describes the results of attempts to deliver, relay, or gateway
                        #   a message to one or more recipients.  In all cases, the Reporting-MTA
                        #   is the MTA that attempted to perform the delivery, relay, or gateway
                        #   operation described in the DSN.  This field is required.
                        $connheader->{'rhost'} ||= $1;

                    } elsif( $e =~ m/\A[Rr]eceived-[Ff]rom-MTA:[ ]*(?:DNS|dns);[ ]*(.+)\z/ ) {
                        # 2.2.4 The Received-From-MTA DSN field
                        #   The optional Received-From-MTA field indicates the name of the MTA
                        #   from which the message was received.
                        #
                        #       received-from-mta-field =
                        #           "Received-From-MTA" ":" mta-name-type ";" mta-name
                        #
                        #   If the message was received from an Internet host via SMTP, the
                        #   contents of the mta-name sub-field SHOULD be the Internet domain name
                        #   supplied in the HELO or EHLO command, and the network address used by
                        #   the SMTP client SHOULD be included as a comment enclosed in
                        #   parentheses.  (In this case, the MTA-name-type will be "dns".)
                        $connheader->{'lhost'} = $1;

                    } elsif( $e =~ m/\A[Aa]rrival-[Dd]ate:[ ]*(.+)\z/ ) {
                        # 2.2.5 The Arrival-Date DSN field
                        #   The optional Arrival-Date field indicates the date and time at which
                        #   the message arrived at the Reporting MTA.  If the Last-Attempt-Date
                        #   field is also provided in a per-recipient field, this can be used to
                        #   determine the interval between when the message arrived at the
                        #   Reporting MTA and when the report was issued for that recipient.
                        #
                        #       arrival-date-field = "Arrival-Date" ":" date-time
                        $connheader->{'date'} = $1;

                    } else {
                        # Get error message
                        next if $e =~ m/\A[ -]+/;
                        next unless $e =~ $Re1->{'error'};

                        # 500 User Unknown
                        # <kijitora@example.jp> Unknown
                        $v->{'alterrors'} .= ' '.$e;
                    }
                }
            }
        } # End of if: rfc822
    } continue {
        # Save the current line for the next loop
        $p = $e;
    }

    BODY_PARSER_FOR_FALLBACK: {
        # Fallback, parse entire message body
        last if $recipients;

        # Failed to get a recipient address at code above
        $match ||= 1 if $mhead->{'from'}    =~ $Re0->{'from'};
        $match ||= 1 if $mhead->{'subject'} =~ $Re0->{'subject'};
        if( defined $mhead->{'return-path'} ) {
            # Check the value of Return-Path of the message
            $match ||= 1 if $mhead->{'return-path'} =~ $Re0->{'return-path'};
        }
        last unless $match;

        my $re_skip = qr{(?>
             \A[-]+=
            |\A\s+\z
            |\A\s*--
            |\A\s+[=]\d+
            |\AHi[ ][!]
            |Content-(?:Description|Disposition|Transfer-Encoding|Type):[ ]
            |(?:name|charset)=
            |--\z
            |:[ ]--------
            )
        }xi;

        my $re_stop  = qr{(?:
             \AContent-Type:[ ]message/delivery-status
            |\AHere[ ]is[ ]a[ ]copy[ ]of[ ]the[ ]first[ ]part[ ]of[ ]the[ ]message
            |\AThe[ ]non-delivered[ ]message[ ]is[ ]attached[ ]to[ ]this[ ]message.
            |\AReceived:[ \t]*
            |\AReceived-From-MTA:[ \t]*
            |\AReporting-MTA:[ \t]*
            |\AReturn-Path:[ \t]*
            |\AA[ ]copy[ ]of[ ]the[ ]original[ ]message[ ]below[ ]this[ ]line:
            |Attachment[ ]is[ ]a[ ]copy[ ]of[ ]the[ ]message
            |Below[ ]is[ ]a[ ]copy[ ]of[ ]the[ ]original[ ]message:
            |Below[ ]this[ ]line[ ]is[ ]a[ ]copy[ ]of[ ]the[ ]message
            |Message[ ]contains[ ].+[ ]file[ ]attachments
            |Message[ ]text[ ]follows:[ ]
            |Original[ ]message[ ]follows
            |The[ ]attachment[ ]contains[ ]the[ ]original[ ]mail[ ]headers
            |The[ ]first[ ]\d+[ ]lines[ ]
            |Unsent[ ]Message[ ]below
            |Your[ ]message[ ]reads[ ][(]in[ ]part[)]:
            )
        }xi;

        my $re_addr = qr{(?:
             \A\s*
            |\A["].+["]\s*
            |\A[ \t]*Recipient:[ \t]*
            |\A[ ]*Address:[ ]
            |addressed[ ]to[ ]
            |Could[ ]not[ ]be[ ]delivered[ ]to:[ ]
            |delivered[ ]to[ ]+
            |delivery[ ]failed:[ ]
            |Did[ ]not[ ]reach[ ]the[ ]following[ ]recipient:[ ]
            |Error-for:[ ]+
            |Failed[ ]Recipient:[ ]
            |Failed[ ]to[ ]deliver[ ]to[ ]
            |generated[ ]from[ ]
            |Intended[ ]recipient:[ ]
            |Mailbox[ ]is[ ]full:[ ]
            |RCPT[ ]To:
            |SMTP[ ]Server[ ][<].+[>][ ]rejected[ ]recipient[ ]
            |The[ ]following[ ]recipients[ ]returned[ ]permanent[ ]errors:[ ]
            |The[ ]following[ ]message[ ]to[ ]
            |Unknown[ ]User:[ ]
            |undeliverable[ ]to[ ]
            |Undeliverable[ ]Address:[ ]*
            |You[ ]sent[ ]mail[ ]to[ ]
            |Your[ ]message[ ]to[ ]
            )
            ['"]?[<]?([^\s\n\r@=]+[@][-.0-9A-Za-z]+[.][0-9A-Za-z]+)[>]?['"]?
        }xi;

        my $b = $dscontents->[ -1 ];
        for my $e ( split( "\n", $$mbody ) ) {
            # Get the recipient's email address and error messages.
            last if $e =~ $Re1->{'endof'};
            last if $e =~ $Re1->{'rfc822'};
            last if $e =~ $re_stop;

            next unless length $e;
            next if $e =~ $re_skip;
            next if $e =~ m/\A[*]/;

            if( $e =~ $re_addr ) {
                # May be an email address
                my $x = $b->{'recipient'} || '';
                my $y = Sisimai::Address->s3s4( $1 );

                if( length $x && $x ne $y ) {
                    # There are multiple recipient addresses in the message body.
                    push @$dscontents, Sisimai::MTA->DELIVERYSTATUS;
                    $b = $dscontents->[ -1 ];
                }
                $b->{'recipient'} = $y;
                $b->{'agent'} = __PACKAGE__->smtpagent.'::Fallback';
                $recipients++;

            } elsif( $e =~ m/[(]expanded[ ]from:[ ]([^@]+[@][^@]+)[)]/ ) {
                # (expanded from: neko@example.jp)
                $b->{'alias'} = Sisimai::Address->s3s4( $1 );
            }
            $b->{'diagnosis'} .= ' '.$e;
        }
    }

    return undef unless $recipients;
    require Sisimai::String;
    require Sisimai::SMTP::Status;

    for my $e ( @$dscontents ) {
        # Set default values if each value is empty.
        map { $e->{ $_ } ||= $connheader->{ $_ } || '' } keys %$connheader;

        if( exists $e->{'alterrors'} && length $e->{'alterrors'} ) {
            # Copy alternative error message
            $e->{'diagnosis'} ||= $e->{'alterrors'};
            if( $e->{'diagnosis'} =~ m/\A[-]+/ || $e->{'diagnosis'} =~ m/__\z/ ) {
                # Override the value of diagnostic code message
                $e->{'diagnosis'} = $e->{'alterrors'} if length $e->{'alterrors'};
            }
            delete $e->{'alterrors'};
        }
        $e->{'diagnosis'} = Sisimai::String->sweep( $e->{'diagnosis'} );

        if( $scannedset ) {
            # Make bounce data by the values returned from Sisimai::MDA->scan()
            $e->{'agent'}     = $scannedset->{'mda'} || __PACKAGE__->smtpagent;
            $e->{'reason'}    = $scannedset->{'reason'} || 'undefined';
            $e->{'diagnosis'} = $scannedset->{'message'} if length $scannedset->{'message'};
            $e->{'command'}   = '';

        } else {
            # Set the value of smtpagent
            $e->{'agent'} = __PACKAGE__->smtpagent;
        }
        $e->{'status'} ||= Sisimai::SMTP::Status->find( $e->{'diagnosis'} );
        $e->{'command'}  = $1 if $e->{'diagnosis'} =~ $Re1->{'command'};

        if( scalar @{ $mhead->{'received'} } ) {
            # Get localhost and remote host name from Received header.
            my $r0 = $mhead->{'received'};
            $e->{'lhost'} ||= shift @{ Sisimai::RFC5322->received( $r0->[0] ) };
            $e->{'rhost'} ||= pop @{ Sisimai::RFC5322->received( $r0->[-1] ) };
        }

        $e->{'date'}  ||= $mhead->{'date'};
        $e->{'spec'}  ||= 'SMTP';
    }
    return { 'ds' => $dscontents, 'rfc822' => $rfc822part };
}

1;
__END__
=encoding utf-8

=head1 NAME

Sisimai::RFC3464 - bounce mail parser class for Fallback.

=head1 SYNOPSIS

    use Sisimai::RFC3464;

=head1 DESCRIPTION

Sisimai::RFC3464 is a class which called from called from only Sisimai::Message
when other Sisimai::MTA::* modules did not detected a bounce reason.

=head1 CLASS METHODS

=head2 C<B<description()>>

C<description()> returns description string of this module.

    print Sisimai::RFC3464->description;

=head2 C<B<smtpagent()>>

C<smtpagent()> returns MDA name or string 'RFC3464'.

    print Sisimai::RFC3464->smtpagent;

=head2 C<B<scan( I<header data>, I<reference to body string>)>>

C<scan()> method parses a bounced email and return results as a array reference.
See Sisimai::Message for more details.

=head1 AUTHOR

azumakuniyuki

=head1 COPYRIGHT

Copyright (C) 2014-2016 azumakuniyuki, All rights reserved.

=head1 LICENSE

This software is distributed under The BSD 2-Clause License.

=cut
