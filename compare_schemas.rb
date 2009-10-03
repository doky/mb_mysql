#!/usr/bin/env ruby

require 'set'
require 'open-uri'

DEFAULT_REPO_LOCATION = "branches/RELEASE_20090524-BRANCH"

puts "! using default repository location: #{DEFAULT_REPO_LOCATION}\n\n" if ARGV[0].nil?
$repository_location = ARGV[0] || DEFAULT_REPO_LOCATION

# works on filenames or urls
def get_statements(uri)
  open(uri) { |fh| fh.read }.
      split("\n").
      map { |line| line.sub(/(.*?)--.*/, '\1') }.
      join.
      split(/;/).
      map { |line| line.strip }
end

def table_definitions(sql_stmts)
  create_table_stmts = sql_stmts.select { |stmt| stmt.match(/^create\s+table/i) }

  # [table_name, column_definitions]
  create_table_stmts.
      map { |stmt| stmt.match(/create\s+table(?:\s+if\s+not\s+exists)?\s+([^\(]+)\((.*)\)/i)[1..-1] }.
      map do |(table_name,columns)|
        [
          # name without surrounding punctuation
          table_name.match(/(\w+)/)[0].downcase,
          # array of [column_name, data_type]
          columns.split(/,\s{3,}/).
              map { |col| col.strip }.
              map { |col| col.match(/^["`]?(\w+)["`]?\s+(.*)$/)[1..-1] }.
              reject { |(col_name,_)| %w[check constraint].include? col_name.downcase }
        ]
      end
end

def get_postgres_ct_stmts
  url = "http://bugs.musicbrainz.org/browser/mb_server/#{$repository_location}/admin/sql/CreateTables.sql?format=txt"
  # create_indexes_url = "http://bugs.musicbrainz.org/browser/mb_server/branches/#{repository_location}/admin/sql/CreateIndexes.sql?format=txt"
  
  stmts = get_statements(url)
end

def get_mysql_ct_stmts
  stmts = get_statements('sql/create_tables.sql')
end

def get_postgres_data
  {
    :tables => table_definitions(get_postgres_ct_stmts),
    :indexes => []
  }
end

def get_mysql_data
  {
    :tables => table_definitions(get_mysql_ct_stmts),
    :indexes => []
  }
end

if $0 == __FILE__
  pg_data = get_postgres_data
  pg_tables = pg_data[:tables]
  pg_table_names = pg_tables.map { |t| t.first }
  puts "postgres has #{pg_data[:tables].length} tables"

  mysql_data = get_mysql_data
  mysql_tables = mysql_data[:tables]
  mysql_table_names = mysql_tables.map { |t| t.first }
  puts "mysql has #{mysql_tables.length} tables"

  puts
  puts 'TABLES'
  puts "mysql has extra tables:  #{ (mysql_table_names - pg_table_names).join(', ') }"
  puts "mysql is missing tables: #{ (pg_table_names - mysql_table_names).join(', ') }"

  shared_tables = mysql_table_names & pg_table_names

  columns_from = lambda { |db_tables,table_name| db_tables.find { |(db_table_name,_)| db_table_name == table_name }.last }
  table_def_pairs = Hash.new do |pairs,table_name|
    pairs[table_name] = {
      :postgres =>  columns_from[pg_tables, table_name],
      :mysql =>     columns_from[mysql_tables, table_name]
    }
  end

  puts
  puts 'COLUMNS'
  found_col_mismatch = nil
  shared_tables.each do |table_name|
    cols = table_def_pairs[table_name]
    mysql_cols = cols[:mysql]
    pg_cols = cols[:postgres]

    mysql_col_names = mysql_cols.map { |col| col.first }
    pg_col_names = pg_cols.map { |col| col.first }

    mysql_extra_cols = mysql_col_names - pg_col_names
    mysql_missing_cols = pg_col_names - mysql_col_names
    if !mysql_extra_cols.empty? || !mysql_missing_cols.empty?
      found_col_mismatch = true
      puts "column mismatch for table #{table_name}"
      puts "  mysql has extra columns:  #{ (mysql_col_names - pg_col_names).join(', ') }" if !mysql_extra_cols.empty?
      puts "  mysql is missing columns: #{ (pg_col_names - mysql_col_names).map { |col| "#{col} (#{pg_cols.find { |pg_col| pg_col.first == col }.last})" }.join(', ') }" if !mysql_missing_cols.empty?
    else
      puts "weird mismatch for #{table_name}: pg has #{pg_col_names.length} and mysql has #{mysql_col_names.length}" if pg_col_names.length != mysql_col_names.length
    end
  end
  puts "all columns matched" unless found_col_mismatch

  puts
  puts 'INDEXES'
  puts '(TODO)'
end
