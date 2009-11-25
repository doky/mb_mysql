#!/usr/bin/env perl

use LWP::UserAgent;
use DBI;

require "Globals.pl";
require "MB_Funcs.pl";
my $version = "2.1";

# FLAGS
my $f_quiet = 0;
my $f_info = 0;
my $f_onlypending = 0;
my $f_keeprunning = 0;
my $f_nonverbose = 0;
my $f_onlytocurrent = 0;
my $f_show_extras = 0;
my $f_skiptorep = 0;
my $f_truncatetables = 0;

# PROCESS FLAGS
foreach $ARG (@ARGV) {
  @parts = split("=", $ARG);
	if($parts[0] eq "-q" || $parts[0] eq "--quiet") {
		$f_quiet = 1;
	} elsif($parts[0] eq "-i" || $parts[0] eq "--info") {
		$f_info = 1;
	} elsif($parts[0] eq "-p" || $parts[0] eq "--onlypending") {
		$f_onlypending = 1;
	} elsif($parts[0] eq "-r" || $parts[0] eq "--keeprunning") {
		$f_keeprunning = 1;
	} elsif($parts[0] eq "-n" || $parts[0] eq "--nonverbose") {
		$f_nonverbose = 1;
	} elsif($parts[0] eq "-s" || $parts[0] eq "--showall") {
		$f_show_extras = 1;
	} elsif($parts[0] eq "-t" || $parts[0] eq "--truncate") {
		$f_truncatetables = 1;
	} elsif($parts[0] eq "-c" || $parts[0] eq "--onlytocurrent") {
		$f_onlytocurrent = 1;
		$f_keeprunning = 1;
	} elsif($parts[0] eq "-g" || $parts[0] eq "--skiptorep") {
		$f_skiptorep = int($parts[1]);
	} elsif($parts[0] eq "-h" || $parts[0] eq "--help") {
		&showhelp();
		exit(0);
	} else {
		die "Unknown option '$parts[0]'\n";
	}
}

sub showhelp {
  print "VERSION: $version\n\n";
  print "-c or --onlytocurrent  Keep updating as many replications as possible until no more replications can\n";
  print "                       be found on the server then quit.\n";
  print "-g=x or --skiptorep=x  Change replication number to 'x'\n";
  print "-h or --help           Show this help.\n";
  print "-i or --info           Only shows the information about the current replication and pending\n";
  print "                       transactions.\n";
  print "-n or --nonverbose     Only print the progress every time a new XID is started. This is to minimise\n";
  print "                       the printing to the console.\n";
  print "-p or --onlypending    Only process pending transactions then quit.\n";
  print "-q or --quiet          Non-verbose. The status of each statement is not printed.\n";
  print "-r or --keeprunning    Keep the script running constantly, automatically checking for new replications\n";
  print "                       every 15 mins (value determined by \$g_rep_chkevery)\n";
  print "-s or --showall        This will show what type of statement (INSERT/UPDATE/DELETE) is being run and\n";
  print "                       how long it takes for the statement to process\n";
  print "-t or --truncate       Force TRUNCATE on Pending and PendindData tables.\n";
}

BEGIN:

# TRUNCATE TABLES
if($f_truncatetables == 1) {
  $sql = "TRUNCATE Pending";
  my $sth = $dbh->prepare($sql);
  $sth->execute;
  $sql = "TRUNCATE PendingData";
  my $sth = $dbh->prepare($sql);
  $sth->execute;
  exit(0);
}

# GET CURRENT REPLICATION AND SCHEMA
$sql = "select * from replication_control";
my $sth = $dbh->prepare($sql);
$sth->execute;
my @row = $sth->fetchrow_array();
my $rep = $row[2];
my $schema = $row[1];

# CHANGE REPLICATION NUMBER
if($f_skiptorep > 0) {
  print "CHANGING REPLICATION NUMBER: $f_skiptorep\n";
  print "Moving ";
  if($rep > $f_skiptorep) {
    print "BACKWARD ";
  } else {
    print "FORWARD ";
  }
  print abs($f_skiptorep - $rep) . " replications.\n";
  
  $dbh->do("UPDATE replication_control SET current_replication_sequence=$f_skiptorep");
  print "Done\n";
  
  exit(0);
}

# FIND IF THERE ARE PENDING TRANSACTIONS
$sql = "SELECT count(*) from Pending";
$sth = $dbh->prepare($sql);
$sth->execute;
@row = $sth->fetchrow_array();
$pending_xactions = $row[0];

if($f_info) {
	print "\nCurrent replication       : " . ($rep + 1);
	$sql = "SELECT * from replication_control";
	my $sth2 = $dbh->prepare($sql);
	$sth2->execute;
	my @row2 = $sth2->fetchrow_array();
	print "\nLast replication finished : " . &format_sql_date($row2[3]);
	print "\n\nPending transactions      : $pending_xactions\n\n";
	exit(0);
}

print "\nCurrent replication is $rep\n\n";
$id = int($rep) + 1;
print "Looking for previous pending changes... ";

if('0' eq $pending_xactions) {
	print "None\n\n";
	if($f_onlypending) {
		exit(0);
	}
	if(!&download($id)) {
		print "\nReplication $id could not be found on the server\n\n";
		exit(0) if(!$f_keeprunning);
		if($f_keeprunning) {
			$wait = $g_rep_chkevery;
			while($wait > 0) {
				print "Trying again in $wait minutes\n";
				sleep(60);
				$wait -= 1;
			}
			goto BEGIN;
		}
	}
	&unzip($id);
	$new_schema_number = &existsNewSchema($rep + 1);
  if($new_schema_number) {
    print "\nCurrent MB schema is out of date!  Version $new_schema_number is now in use; schema needs to be resolved.  Quitting.\n";
    exit 1;
    #   BEGINSCHEMA:
    #   if(!&download_schema($schema + 1)) {
    #     print "New schema not available yet.\n";
    #     if($f_keeprunning) {
    #       $wait = $g_rep_chkevery;
    #       while($wait > 0) {
    #         print "Trying again in $wait minutes\n";
    #         sleep(60);
    #         $wait -= 1;
    #       }
    #       goto BEGINSCHEMA;
    #     }
    #     exit(0);
    #   }
    #   &unzip_schema($schema + 1);
    #   &run_schema($schema + 1);
    #   &clean_sid($schema + 1);
  }
	&load_data($id);
} else {
	print "$pending_xactions pending\n\n";
	&run_transactions();
}

if($f_keeprunning) {
	goto BEGIN;
}

sub format_sql_date {
	$str = $_[0];
	return substr($str, 8, 2) . ' ' . $g_months[int(substr($str, 5, 2))] . ' ' . substr($str, 0, 4) . ' ' . substr($str, 11, 8);
}

# sub run_schema {
#   $sid = $_[0];
#   system("perl replication/schema-$sid/update.pl");
# }

# sub clean_sid {
#   $sid = $_[0];
# 
#   # Clean up. Remove schema files.
#   system("rm -f replication/schema-$sid.tar.bz2");
#   system("rm -f -r replication/schema-$sid");
# }

sub download {
  $id = $_[0];
	print "===== $id =====\n";
	
	# make sure that the file isn't already downloaded
	if(-e "replication/replication-$id.tar.bz2") {
		print localtime() . ": Downloading... Done\n";
  	return 1;
	}

  print localtime() . ": Downloading... ";
  $localfile = "replication/replication-$id.tar.bz2";
  $url = "ftp://ftp.musicbrainz.org/pub/musicbrainz/data/replication/replication-$id.tar.bz2";
  $ua = LWP::UserAgent->new();
  $request = HTTP::Request->new('GET', $url);
  $resp = $ua->request($request, $localfile);
  $found = 0;
  
  use HTTP::Status qw( RC_OK RC_NOT_FOUND RC_NOT_MODIFIED );
  if($resp->code == RC_NOT_FOUND) {
    # file not found
  } elsif($resp->code == RC_OK || $resp->code == RC_NOT_MODIFIED) {
    $found = 1;
  }

  print "Done\n";
  return $found;
}

# sub download_schema {
#   $sid = $_[0];
#   print "DOWNLOADING SCHEMA: $sid\n";
#   
#   # make sure that the file isn't already downloaded
#   if(-e "replication/schema-$sid.tar.bz2") {
#     print localtime() . ": Downloading Schema... Done\n";
#     return 1;
#   }
# 
#   print localtime() . ": Downloading Schema... ";
#   $localfile = "replication/schema-$sid.tar.bz2";
#   $url = $g_schema_url . "schema-$sid.tar.bz2";
#   $ua = LWP::UserAgent->new();
#   $request = HTTP::Request->new('GET', $url);
#   $resp = $ua->request($request, $localfile);
#   $found = 0;
#   
#   use HTTP::Status qw( RC_OK RC_NOT_FOUND RC_NOT_MODIFIED );
#   if($resp->code == RC_NOT_FOUND) {
#     # file not found
#   } elsif($resp->code == RC_OK || $resp->code == RC_NOT_MODIFIED) {
#     $found = 1;
#   }
# 
#   print "Done\n";
#   return $found;
# }

sub existsNewSchema {
  $id = $_[0];

  open(SCHEMAFILE, "replication/$id/SCHEMA_SEQUENCE") || die "Could not open 'replication/$id/SCHEMA_SEQUENCE'\n";
  @data = <SCHEMAFILE>;
  $new_schema = $data[0];
  chomp($new_schema);
  close(SCHEMAFILE);
  return 0 if($new_schema == $schema);
  return $new_schema;
}

sub unzip {
  $id = $_[0];

  print localtime() . ": Uncompressing... ";
  mkdir("replication/$id");
  system("tar -xjf replication/replication-$id.tar.bz2 -C replication/$id");
  print "Done\n";
  return 1;
}

# sub unzip_schema {
#   $sid = $_[0];
# 
#   print localtime() . ": Uncompressing Schema... ";
#   mkdir("replication/schema-$sid");
#   system("tar -xjf replication/schema-$sid.tar.bz2 -C replication");
#   print "Done\n";
#   return 1;
# }

sub fmod {
	return 0 if($_[1] == 0);
	$times = int($_[0] / $_[1]);
	return ($_[0] - ($times * $_[1]));
}

sub padzero {
  if($_[0] eq int($_[0])) { return "$_[0].0"; }
  return $_[0];
}

sub round {
	$rem = &fmod($_[0], $_[1]);
	return &padzero($_[0] + ($_[1] - $rem)) if($rem >= ($_[1] * 0.5));
	return &padzero($_[0] - $rem);
}

sub run_transactions {
	# make sure there are transactions in the table
	$sql = "SELECT count(*) from Pending";
	my $sth = $dbh->prepare($sql);
	$sth->execute;
	my @row = $sth->fetchrow_array();
	if($row[0] eq '0') {
		return 0;
	}
	
  $sql = "SELECT Pending.XID, MAX(SeqId) FROM Pending GROUP BY Pending.XID ORDER BY MAX(Pending.SeqId)";
  $sth = $dbh->prepare($sql);
  $sth->execute;

	use Time::HiRes qw( gettimeofday tv_interval );
	my $t1 = [gettimeofday], $t2;
	my $interval;
  my $lastxid = 0;
	my $rows = 0;
	my $strows = 0;

	$temp = $dbh->prepare("SELECT count(1) FROM Pending");
  $temp->execute;
  @row = $temp->fetchrow_array();
	$total_statements = $row[0];
  $temp->finish;

	my $starttime = time();

	while(@row = $sth->fetchrow_array()) {
		my $XID = $row[0];
		my $maxSeqId = $row[1];
		my $seqId;

		if ($skip_seqid and $maxSeqId <= $skip_seqid) {
			print localtime() . ": Ignoring SeqId #$maxSeqId\n";
			next;
		}

		my $query2 = "SELECT count(*) FROM Pending WHERE XID=$XID";
		my $sth2 = $dbh->prepare($query2);
    $sth2->execute;
    @temprow = $sth2->fetchrow_array();
		my %stmt_type = ( 'i' => 'INSERT', 'u' => 'UPDATE', 'd' => 'DELETE' );
		if($temprow[0] ne "0") {
			my (@row2, $curTuple);
			my $query = <<SQL;
SELECT p.SeqId as 'SeqId', p.TableName as 'TableName', p.Op as 'Op', pd1.Data as 'Keys', pd2.Data as 'Data'
FROM Pending as p
  LEFT OUTER JOIN PendingData as pd1 on (p.SeqId=pd1.SeqId and pd1.IsKey = 't')
  LEFT OUTER JOIN PendingData as pd2 on (p.SeqId=pd2.SeqID and pd2.IsKey = 'f')
WHERE p.XID=$XID
ORDER BY p.SeqId
SQL
			$slave = $dbh->prepare($query);
  		$slave->execute;

  		while(@row2 = $slave->fetchrow_array()) {
  		  $operation = $row2[2];
				my $temp_time = time();
				if($f_show_extras == 1) {
					print "$stmt_type{$operation} ";
				}
				if (!mirrorCommand($operation, \@row2, $XID)) {
					die "Mirror command failed.\n";
				}

				if($total_statements != 0) {
					$est = 100 * $strows / $total_statements;
				} else {
					$est = "-";
				}
				$time = time() - $starttime;
				my $stmt_time = time() - $temp_time;
				if(!$f_quiet) {
					if($f_show_extras == 1) {
						print "(" . &formattime($stmt_time) . ") : ";
					}
					if($f_nonverbose) {
						if($lastxid != $XID) {
							printf("XIDs: %5d   Stmts: %5s   est%%: %6s%%   Elapsed: %12s   ETA: %12s\n", $rows, $strows + 1, &round($est, 0.1), &formattime($time), ($est == 0) ? "-" : &formattime($time * (100 - $est) / $est));
						}
					} else {
						printf("XIDs: %5d   Stmts: %5s   est%%: %6s%%   Elapsed: %12s   ETA: %12s\n", $rows, $strows + 1, &round($est, 0.1), &formattime($time), ($est == 0) ? "-" : &formattime($time * (100 - $est) / $est));
					}
				}
				++$strows;
				$dbh->do("DELETE FROM Pending WHERE SeqId=$row2[0]") or warn "\nCould not remove Pending record\n";
				$dbh->do("DELETE FROM PendingData WHERE SeqId=$row2[0]") or warn "\nCould not remove PendingData record\n";
				$lastxid = $XID;
			}
		}
		++$rows;
	}
	if($f_nonverbose) {
		printf("XIDs: %5d   Stmts: %5s   est%%: %6s%%   Elapsed: %12s   ETA: %12s\n", $rows, $strows + 1, &round($est, 0.1), &formattime($time), ($est == 0) ? "-" : &formattime($time * (100 - $est) / $est));
	}

	$temp = $dbh->prepare("SELECT * FROM replication_control");
  $temp->execute;
  @row = $temp->fetchrow_array();
	$nextrep = $row[2];
  $temp->finish;

  # update replication id
  &run_sql("UPDATE replication_control SET current_replication_sequence=" . ($rep + 1));

	# Clean up. Remove old replication
	system("rm -f replication/replication-$nextrep.tar.bz2");
	system("rm -f -r replication/$nextrep");
}

sub load_data {
  $id = $_[0];

  # make sure there are no pending transactions before cleanup
  $temp = $dbh->prepare("SELECT count(*) FROM Pending");
  $temp->execute;
  @row = $temp->fetchrow_array();
  $temp->finish;
  if($row[0] ne '0') {
    print "Unexpectedly found pending transactions. Quitting.\n";
    exit 1;
  }

  print localtime() . ": Loading pending tables... ";
  open(TEMPSQL, "> sql/temp.sql");
  for my $pending_table (qw(Pending PendingData)) {
    print TEMPSQL "LOAD DATA LOCAL INFILE 'replication/$id/mbdump/$pending_table' INTO TABLE $pending_table\n";
    print TEMPSQL "FIELDS TERMINATED BY '\\t' ENCLOSED BY '' ESCAPED BY '\\\\'\n";
    print TEMPSQL "LINES TERMINATED BY '\\n' STARTING BY ''\n;\n";
  }
  close(TEMPSQL);
  system("$g_prog --local-infile -u $g_db_user --password=$g_db_pass -P $g_db_port -h $g_db_host $g_db_name < sql/temp.sql");
  print "Done\n";

  print localtime() . ": Processing Transactions...\n";
  &run_transactions();
  print "Finished\n";

  return 1;
}
