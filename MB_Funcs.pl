####
## MB_Funcs.pl
## Contains all the original MBz functions (ported from PostgreSQL) and a few extra ones.
##
## VERSION: 2.0
####

sub formattime {
	my $left = $_[0];
  my $hours = int($left / 3600);
	$left -= $hours * 3600;
  my $mins = int($left / 60);
	$left -= $mins * 60;
  my $secs = int($left);

  my $r = "";
  if($hours > 0) {
		$r .= $hours . "h ";
	}
  if($mins < 10) {
		$r .= " ";
	}
	$r .= $mins . "m ";
  if($secs < 10) {
		$r .= " ";
	}
	$r .= $secs . "s";
  return $r;
}

sub run_sql {
  return $dbh->do($_[0]) or &sql_error($dbh->errstr, $_[0]);
}

sub sql_error {
  ($err, $stmt) = @_;
  
  # is it a duplicate ID?
  return if((substr($err, 0, 15) eq "Duplicate entry") && ($g_die_on_dupid == 0));
  
	if($g_die_on_error == 1) {
		die "SQL: '$stmt'\n\n";
	} else {
	  print "SQL: '$stmt'\n\n";
  }
}

sub update_livestats {
  ($name, $action, $val) = @_;
  if($action eq "add") {
    &run_sql("UPDATE livestats SET val=val+$val WHERE name=\"$name\"");
  } elsif($action eq "subtract") {
    &run_sql("UPDATE livestats SET val=val-$val WHERE name=\"$name\"");
  } elsif($action eq "set") {
    &run_sql("UPDATE livestats SET val=$val WHERE name=\"$name\"");
  }
}

sub substituteArgs {
  my @args = @_;
  my $i = 1;
  my $r = "";
  for($j = 0; $j < length($args[0]); ++$j) {
    if(substr($args[0], $j, 1) eq '?') {
      $r .= $args[$i] if(defined($args[$i]));
      ++$i;
    } else {
      $r .= substr($args[0], $j, 1);
    }
  }
  return $r;
}

sub smartSQL {
  open(NEW_SQL, $_[0]);
	@lines = <NEW_SQL>;
  my $sql_stmt;
  my $t1 = 0;
  my $t2 = 0;
	print "\n";
	foreach $line (@lines) {
    chomp($line);
	 	next if($line eq "");
    if(substr($line, 0, 2) eq "--") {
			@parts = split(/\s/, $line);
			if($parts[1] eq "new" || $parts[1] eq "create") {
	  		$t1 = time();
				print localtime() . ": Creating table $parts[2]\n";
			} elsif($parts[1] eq "index") {
	  		$t1 = time();
				print localtime() . ": Indexing table $parts[2]\n";
			} elsif($parts[1] eq "alter") {
	  		$t1 = time();
				print localtime() . ": Alter table $parts[2]\n";
			} elsif($parts[1] eq "primary") {
	  		$t1 = time();
				print localtime() . ": Adding primary key to $parts[2]\n";
			} elsif($parts[1] eq "rename") {
	  		$t1 = time();
				print localtime() . ": Renaming table $parts[2]\n";
			} elsif($parts[1] eq "view") {
	  		$t1 = time();
				print localtime() . ": Creating view $parts[2]\n";
			} elsif($parts[1] eq "drop") {
	  		$t1 = time();
				print localtime() . ": Droping table $parts[2]\n";
			} elsif($parts[1] eq "end") {
				&run_sql($sql_stmt) if($sql_stmt ne "");
				$t2 = time();
				print "Finished (" . &formattime($t2 - $t1) . ")\n\n";
			}
			$sql_stmt = "";
		} else {
			$sql_stmt .= "$line\n";
		}
  }
}

# These three subs handle INSERT, UPDATE and DELETE operations respectively.
# Each one accepts a table name and one or two sets of column-value pairs;
# each one then returns an SQL statement and the arguments to go with it.
# The table name will already be quoted and qualified, if required.

sub table_name {
	$table = $_[0];
	$table = substr($table, 1, length($table) - 2);
	if($table eq "release") {
		$table = '`release`';
	}
	$table = "$g_db_name." . $table;
	return $table
}

sub normalize_date {
  my $str = $_[0];
  $str =~ s/(\d{4}-\d{2}-\d{2}\s\d{2}:\d{2}:\d{2})\.\d+\+\d+/$1/;
  return $str;
}

sub sql_escape {
	my $k = $_[0];
	$k =~ s/\\/\\\\/g;
	$k =~ s/"/\\"/g;
	$k =~ s/'/\\'/g;
	$k =~ s/\n/\\n/g;
	$k =~ s/\t/\\t/g;
	return $k;
}

# does the opposite to sql_escape to an array
sub sql_unescape {
	my @k = @_;
	my $i = 0;
	foreach $k (@k) {
	  $k[$i] =~ s/\\\\/\\/g;
	  $k[$i] =~ s/\\"/"/g;
	  $k[$i] =~ s/\\'/'/g;
	  $k[$i] =~ s/\\n/\n/g;
	  $k[$i] =~ s/\\t/\t/g;
	  ++$i;
  }
	return @k;
}

# It seems there's not enough information to deterministically get anything but status back out (since it's always between 100-103) from pg dump,
#  since I've seen the following values in the dump: {0,4}, {0,100}, {0,0}, {0}, {0,9,100}
# So for now we are just going to convert 'attributes' into an integer for status.  if the array contains a value between 100-103, we use that. else, 0.
# As for release type, that can be still be retrieved from a release's release_group.type
sub procAttributes {
  $b = substr($_[0], 1, length($_[0]) - 2);
  @nums = split(",", $b);

  @status_attributes = grep { $_ >= 100 && $_ <= 103 } @nums;
  return $status_attributes[0] || 0;
}

sub prepare_insert {
  my ($table, $values) = @_;
  $table = &table_name($table);
  %$values or die;

  my @column_names = ();
  my @args = ();
  foreach $col (keys %$values) {
    if (defined(my $value = $values->{$col})) {
      $value = &normalize_date(&sql_escape($value));
      if ($col eq "attributes") {
        $col = "status";
        $value = &procAttributes($value);
      }
      push(@column_names, $col);
      push(@args, $value);
    }
  }
  my $colnames = join(", ", map { "`$_`" } @column_names);
  my $params = join(", ", map { '"?"' } @args);

  my $sql = qq[INSERT INTO $table ($colnames) VALUES ($params)];
  return ($sql, \@args);
}

sub prepare_update {
  my ($table, $keys, $values) = @_;
  $table = &table_name($table);
  %$keys or die;
  %$values or die;

  my @clause_items = ();
  my @setargs = ();
  foreach $col (keys %$values) {
    if (defined(my $value = $values->{$col})) {
      $value = &normalize_date(&sql_escape($value));
      if ($col eq "attributes") {
        $col = "status";
        $value = &procAttributes($value);
      }
      push(@clause_items, qq[`$col` = "?"]);
      push(@setargs, $value);
    } else {
      push(@clause_items, qq[`$col` = NULL]);
    }
  }

  my $setclause = join(", ", @clause_items);
  my ($whereclause, $whereargs) = make_where_clause($keys);
  die "where clause unexpectedly empty" if($whereclause eq "");
  my $sql = qq[UPDATE $table SET $setclause WHERE $whereclause];
  my @args = (@setargs, @$whereargs);
  return($sql, \@args);
}

sub prepare_delete {
	my ($table, $keys) = @_;
	$table = &table_name($table);
	%$keys or die;

	my ($whereclause, $whereargs) = make_where_clause($keys);
  die "where clause unexpectedly empty" if($whereclause eq "");

	my $sql = qq[DELETE FROM $table WHERE $whereclause];
	return($sql, $whereargs);
}

# Given a hash of column-value pairs, construct a WHERE clause (using SQL
# placeholders) and a list of arguments to go with it.
sub make_where_clause {
  my $keys = $_[0]; # as returned by unpack_data
  $keys or die;
  %$keys or die;

  my @conditions;
  my @args;

  for my $column (sort keys %$keys) {
    if (defined(my $value = $keys->{$column})) {
      push @conditions, qq[`$column` = "?"];
      push @args, $value;
    } else {
      push @conditions, qq[`$column` IS NULL];
    }
  }

  my $clause = join " AND ", @conditions;
  return ($clause, \@args);
}

sub mirrorInsert {
	my ($row, $transId)  = @_;
	my $seqId = $row->[0];
	my $tableName = $row->[1];
	my $packed_values = $row->[4];

	my $values = &unpack_data($packed_values) or die;

	my ($statement, $args) = &prepare_insert($tableName, $values);

	print localtime() . " : INSERT INTO $tableName\n" if $short_sql;
	show_long_sql($statement, $args) if $long_sql;
	$rec_count = 0;
	$rec_count = &run_sql(&substituteArgs($statement, @$args));
	if($g_livestats) {
	  &update_livestats("count." . substr($table, 15, length($table) - 15), "add", $rec_count);
	  &update_livestats("count.all", "add", $rec_count);
	  &update_livestats("global.inserts", "add", 1);
	}
	
	# download new cover
	if($tableName eq "\"album_amazon_asin\"" && $g_download_new_covers) {
	  system("perl DownloadCover.pl -f -i=" . $values->{'album'});
	}

	return 1;
}

sub mirrorDelete {
	my ($row, $transId) = @_;
	my $seqId = $row->[0];
	my $tableName = $row->[1];
	my $packed_keys = $row->[3];

	my $keys = &unpack_data($packed_keys) or die;

	my ($statement, $args) = &prepare_delete($tableName, $keys);

	print localtime() . " : DELETE FROM $tableName\n" if $short_sql;
	show_long_sql($statement, $args) if $long_sql;
	$rec_count = 0;
	$rec_count = &run_sql(&substituteArgs($statement, @$args));
	if($g_livestats) {
	  &update_livestats("count." . substr($table, 15, length($table) - 15), "subtract", $rec_count);
	  &update_livestats("count.all", "subtract", $rec_count);
	  &update_livestats("global.deletes", "add", 1);
	}

	return 1;
}

sub mirrorUpdate {
	my ($row, $transId) = @_;
	my $seqId = $row->[0];
	my $tableName = $row->[1];
	my $packed_keys = $row->[3];
	my $packed_values = $row->[4];

	my $keys = &unpack_data($packed_keys) or die;
	my $values = &unpack_data($packed_values) or die;

	my ($statement, $args) = &prepare_update($tableName, $keys, $values);

	print localtime() . " : UPDATE $tableName\n" if $short_sql;
	show_long_sql($statement, $args) if $long_sql;
	$rec_count = 0;
	$rec_count = &run_sql(&substituteArgs($statement, @$args));
	&update_livestats("global.updates", "add", 1) if($g_livestats);
	
	# download new cover
	if($tableName eq "\"album_amazon_asin\"" && $g_download_new_covers) {
	  system("perl DownloadCover.pl -f -i=" . $values->{'album'});
	}

	return 1;
}

sub show_long_sql {
	my ($statement, $args) = @_;
	printf "%s : %s (%s)\n",
		scalar(localtime),
		$statement,
		join(" ", map { defined() ? $_ : "NULL" } @$args),
		;
}

sub mirrorCommand {
  my ($op, $row, $transId)  = @_;

  my $table = $row->[1];
  $table =~ s/^"public"\.//;
  $row->[1] = $table;

  if($op eq 'i') {
    return mirrorInsert($row, $transId);
  } elsif($op eq 'd') {
    return mirrorDelete($row, $transId);
  } elsif($op eq 'u') {
    return mirrorUpdate($row, $transId);
  }

  return 0;
}

# Given a packed string from "PendingData"."Data", this sub unpacks it into
# a hash of columnname => value.  It returns the hashref, or undef on failure.
# Basically it's the opposite of "packageData" in pending.c

sub unpack_data {
	my $packed = $_[0];
	my %answer;

	while (length($packed)) {
		my ($k, $v) = $packed =~ m/
			\A
			"(.*?)"		# column name
			=
			(?:
				'
				(
					(?:
						\\\\	# two backslashes == \
						| \\'	# backslash quote == '
						| ''	# quote quote also == '
						| [^']	# any other char == itself
					)*
				)
				'
			)?			# NULL if missing
			\x20		# always a space, even after the last column-value pair
		/sx or warn("Failed to parse: [$packed]"), return undef;

		$packed = substr($packed, $+[0]);

		if (defined $v) {
			my $t = '';
			while (length $v) {
				$t .= "\\", next if $v =~ s/\A\\\\//;
				$t .= "'", next if $v =~ s/\A\\'// or $v =~ s/\A''//;
				$t .= substr($v, 0, 1, '');
			}
			$v = $t;
		}

		$answer{$k} = $v;
	}

	return \%answer;
}

1;
