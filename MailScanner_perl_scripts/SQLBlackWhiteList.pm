#
#   MailScanner - SMTP E-Mail Virus Scanner
#   Copyright (C) 2002  Julian Field
#
#   $Id: SQLBlackWhiteList.pm,v 1.4 2011/12/14 18:21:28 lorodoes Exp $
#
#   This program is free software; you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program; if not, write to the Free Software
#   Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
#
#   The author, Julian Field, can be contacted by email at
#      Jules@JulianField.net
#   or by paper mail at
#      Julian Field
#      Dept of Electronics & Computer Science
#      University of Southampton
#      Southampton
#      SO17 1BJ
#      United Kingdom
#

package MailScanner::CustomConfig;

use strict 'vars';
use strict 'refs';
no  strict 'subs'; # Allow bare words for parameter %'s

use vars qw($VERSION);

### The package version, both in 1.23 style *and* usable by MakeMaker:
$VERSION = substr q$Revision: 1.4 $, 10;

use DBI;
my(%Whitelist, %Blacklist);
my($wtime, $btime);
my($refresh_time) = 15;		# Time in minutes before lists are refreshed

#
# Initialise SQL spam whitelist and blacklist
#
sub InitSQLWhitelist {
  MailScanner::Log::InfoLog("Starting up SQL Whitelist");
  my $entries = CreateList('whitelist', \%Whitelist);
  MailScanner::Log::InfoLog("Read %d whitelist entries", $entries);
  $wtime = time();
}

sub InitSQLBlacklist {
  MailScanner::Log::InfoLog("Starting up SQL Blacklist");
  my $entries = CreateList('blacklist', \%Blacklist);
  MailScanner::Log::InfoLog("Read %d blacklist entries", $entries);
  $btime = time();
}

#
# Lookup a message in the by-domain whitelist and blacklist
#
sub SQLWhitelist {
  # Do we need to refresh the data?
  if ( (time() - $wtime) >= ($refresh_time * 60) ) {
   MailScanner::Log::InfoLog("Whitelist refresh time reached");
   InitSQLWhitelist();
  }
  my($message) = @_;
  return LookupList($message, \%Whitelist);
}

sub SQLBlacklist {
  # Do we need to refresh the data?
  if ( (time() - $btime) >= ($refresh_time * 60) ) {
   MailScanner::Log::InfoLog("Blacklist refresh time reached");
   InitSQLBlacklist();
  }
  my($message) = @_;
  return LookupList($message, \%Blacklist);
}


#
# Close down the SQL whitelist and blacklist
#
sub EndSQLWhitelist {
  MailScanner::Log::InfoLog("Closing down SQL Whitelist");
}

sub EndSQLBlacklist {
  MailScanner::Log::InfoLog("Closing down SQL Blacklist");
}

sub CreateList {
  my($type, $BlackWhite) = @_;
  my($dbh, $sth, $sql, $to_address, $from_address, $count, $filter);
  my($db_name) = 'mailscanner';
  my($db_host) = 'localhost';
  my($db_user) = 'mailwatch';
  my($db_pass) = 'mailwatch';
  
  # Connect to the database
  $dbh = DBI->connect("DBI:mysql:database=$db_name;host=$db_host",
                      $db_user, $db_pass,
                      {PrintError => 0}); 

  # Check if connection was successfull - if it isn't
  # then generate a warning and continue processing.
  if (!$dbh) {
   MailScanner::Log::WarnLog("Unable to initialise database connection: %s", $DBI::errstr);
   return;
  }

  $sql = "SELECT to_address, from_address FROM $type";
  $sth = $dbh->prepare($sql);
  $sth->execute;
  $sth->bind_columns(undef,\$to_address,\$from_address);
  $count = 0;
  while($sth->fetch()) {
   $BlackWhite->{lc($to_address)}{lc($from_address)} = 1; # Store entry
   $count++;
  }  

    $sql = "SELECT filter, from_address FROM $type INNER JOIN user_filters ON $type.to_address = user_filters.username";
  $sth = $dbh->prepare($sql);
  $sth->execute;
  $sth->bind_columns(undef,\$filter,\$from_address);
  while($sth->fetch()) {
   $BlackWhite->{lc($filter)}{lc($from_address)} = 1; # Store entry
   $count++;
  }

  
  # Close connections  
  $sth->finish();
  $dbh->disconnect();

  return $count;
}

#
# Based on the address it is going to, choose the right spam white/blacklist.
# Return 1 if the "from" address is white/blacklisted, 0 if not.
#
sub LookupList {
  my($message, $BlackWhite) = @_;

  return 0 unless $message; # Sanity check the input

  # Find the "from" address and the first "to" address
  my($from, $fromdomain, @todomain, $todomain, @to, $to, $ip, $ip1, $ip1c, $ip2, $ip2c, $ip3, $ip3c, $subdom, $i, @keys, @subdomains);
  $from       = $message->{from};
  $fromdomain = $message->{fromdomain};
  # create a array of subdomains for subdomain wildcard matching
  #   e.g. me@this.that.example.com generates subdomain list of ('that.example.com', 'example.com')
  #   wildcards of *.com, *.uk, *.gov, etc will never be matched for safety's sake (though *.gov.uk could be)
  $subdom = $fromdomain;
  @subdomains = ();
  while ($subdom =~ /.*?\.(.*\..*)/) {
    $subdom = $1;
    push (@subdomains, "*." . $subdom);
  }
  @todomain   = @{$message->{todomain}};
  $todomain   = $todomain[0];
  @to         = @{$message->{to}};
  $to         = $to[0];
  $ip         = $message->{clientip};
  # match on leading 3, 2, or 1 octets
  $ip =~ /(\d{1,3}\.)(\d{1,3}\.)(\d{1,3}\.)/;  # get 1st three octets of IP
  $ip3 = "$1$2$3";
  $ip3c = substr($ip3, 0, -1);
  $ip2 = "$1$2";
  $ip2c = substr($ip2, 0, -1);
  $ip1 = $1;
  $ip1c = substr($ip1, 0, -1);

  # $ip1, $ip2, $ip3 all end in a trailing "."

  # It is in the list if either the exact address is listed,
  # the domain is listed,
  # the IP address is listed,
  # the first 3, 2, or 1 octets of the ipaddress are listed with or without a trailing dot
  # or a subdomain match of the form *.subdomain.example.com is listed
  
  @keys = ($to, $todomain, 'default');
  foreach (@keys) {
    $i = $_;
    return 1 if $BlackWhite->{$i}{$from};
    return 1 if $BlackWhite->{$i}{$fromdomain};
    return 1 if $BlackWhite->{$i}{'@' . $fromdomain};
    return 1 if $BlackWhite->{$i}{$ip};
    return 1 if $BlackWhite->{$i}{$ip3};
    return 1 if $BlackWhite->{$i}{$ip3c};
    return 1 if $BlackWhite->{$i}{$ip2};
    return 1 if $BlackWhite->{$i}{$ip2c};
    return 1 if $BlackWhite->{$i}{$ip1};
    return 1 if $BlackWhite->{$i}{$ip1c};
    foreach (@subdomains) {
      return 1 if $BlackWhite->{$i}{$_};
    }
  }
  return 1 if $BlackWhite->{$to}{'default'};
  return 1 if $BlackWhite->{$todomain}{'default'};

  # It is not in the list
  return 0;
}

1;
