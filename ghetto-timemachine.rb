#!/usr/bin/ruby -w
#-----------------------------------------------------------------------------
# Name        :  ghetto-timemachine.rb
# Author      :  Mike Hanby < mhanby at uab.edu >
# Organization:  University of Alabama at Birmingham
# Description :  This script is used for backing up a *NIX workstation using the
#     classic Rsync using Hardlinks rotation technique described at this URL:
#     http://www.mikerubel.org/computers/rsync_snapshots/ 
#                 
# Usage       :  $0 --src ~/Documents --dest /backups/userA --excludes \*.iso,.svn
# Date        :  2012-03-20 10:30:19
# Type        :  Utility
#
#-----------------------------------------------------------------------------
# History
# 20120329 - mhanby - fixed small bug where script wasn't able to create net/ssh object
#   if user didn't specify a remote user in the destination (user@srv:/path)
#   The script will now use the current shell account if it's not specified in the dest
# 20120328 - mhanby - I've moved much of the file and directory operations into
#   methods so that the method handles all of the local / remote file system
#   specific code
#    * mkdir(dir, ssh)
#    * rmdir(dir, ssh)
#    * mvdir(src, dest, ssh)
#    * soft_link(dir, link, ssh)
#    * hard_link(src, dest, ssh)
#    * disk_free(path, ssh)
#    * run_rsync(opts, src, dest, ssh)
#    * update_mtime(dest, ssh)
#
# 20120327 - mhanby - I originally intended to use net-ssh for remote commands
#   and net-sftp for directory operations (create, delete, rename) thinking sftp
#   was better suited for that. Based on testing, it's much easier doing all of
#   the remote operations using net-ssh.
#
# 20120324 - mhanby - adding support for backing up to remote storage over SSH
#   using net-ssh and net-sftp gems
#   Notes on installing and using gems:
#   1. Add the following to ~/.bashrc
#     export GEM_HOME=$HOME/.ruby/lib/ruby/gems/1.8
#     export RUBYLIB=$HOME/.ruby/lib:$HOME/.ruby/lib/site_ruby/1.8:$RUBYLIB
#   2. Install rubygems package (alternatively, download and stall it manually
#   3. Install the gems
#       gem install net-ssh
#       gem install net-sftp
#
# 20120323 - mhanby - Fixed bug in the summary report, needed a new time object
#   to display the finish time, report was displaying start time twice
#
# 20120322 - mhanby - Created new hard_link method that runs the cp -al system
#   command, replaced all refernces with the new method call hard_link(src, dest)
#   
#   Added code to handle spaces in the paths
# 
# 20120322 - mhanby - Initial version, ported code from my Perl script of the
#   same name as an exercise in Ruby
#
#-----------------------------------------------------------------------------
# Todo / Things that don't work
# FIXED - 1.  Source and Dest with spaces in the path don't currently work.
#     This is tricky because some commands expect spaces to be escaped (system
#     commands), where as Ruby FileUtils expect non escaped
# WONTFIX - 2.  SAMBA / CIFS
#   a.  CIFS/SMB doesn't appear to support creation of hard links. I've only tested
#       this on nas-02, so I'm not sure yet if this is a global SMB thing, or can
#       be modified in smb.conf
#       Thus, the script doesn't currently support SMB and will fail with messages
#       similar to
#       cp: cannot create link `/media/cifs/backup/daily/monday': Function not
#       implemented
#   b.  If we resolve #2 above, may need to add switch to support destinations
#       that don't support setting permissions and time,
#       example "rsync -a" to a CIFS mount will produce a number of
#       errors. Rsync options
#       -a, --archive               archive mode; same as -rlptgoD (no -H)
#           --no-OPTION             turn off an implied OPTION (e.g. --no-D)
#       -O, --omit-dir-times        omit directories from --times
#       -r, --recursive             recurse into directories
#       Possibly use "rsync -a --no-p --no-t"
#   c.  Current testing unable to copy .files to the SMB mount (i.e. .bashrc)
# FIXED - 4.  Figure out a way to allow this script to write to a remote --dest that is
#     accessible via ssh (sftp, rsync -e ssh, etc...)
#-----------------------------------------------------------------------------
require 'optparse' # CLI Option Parser
require 'fileutils' # allow recursive deletion of directory

copywrite = "Copyright (c) 2012 Mike Hanby, University of Alabama at Birmingham IT Research Computing."

options = Hash.new # Hash to hold all options parsed from CLI

optparse = OptionParser.new()  do |opts|
  # Help screen banner
  opts.banner = "#{copywrite}
  
  Backs up the provided SRC to DEST using rsync and hardlinks to provide
  an incremental backup solution without duplicating consumption of storage
  for unmodified files.

  Usage: #{$0} [options] --src PATH --dest PATH"
  
  # Define the options and what they do
  # debug
  options[:debug] = nil
  opts.on('-v', '--debug', 'Script Debugging Output') do
    options[:debug] = true
  end
  
  # source directory
  options[:source] = nil
  opts.on('-s', '--src', '--source FILE', 'Local source directory') do |src|
    options[:source] = src
  end
  
  # destination directory
  options[:dest] = nil
  opts.on('-d', '--dest FILE', 'Local or remote destination directory\nFor remote use syntax: user@host:/PATH') do |dst|
    options[:dest] = dst
  end
  
  # Files or directories to exclude
  options[:excludes] = nil
  opts.on('-e', '--excludes Pattern1,Pattern2,PatternN', Array, 'Can specify multiple patterns to exclude separated by commas. See man rsync for PATTERN details') do |exc|
    options[:excludes] = exc
  end
  
  # help
  options[:help] = false
  opts.on('-?', '-h', '--help', 'Display this help screen') do
    puts opts
    exit
  end
end

# parse! removes the processed args from ARGV
optparse.parse!

raise "\nMandatory argument --src is missing, see --help for details\n" if options[:source].nil?
raise "\nMandatory argument --dest is missing, see --help for details\n" if options[:dest].nil?

# variables
debug = options[:debug]
source = options[:source]
dest = options[:dest] # will get trimmed to only include the path
full_dest = dest # this var will contain full unaltered dest, including user, srv, path
local_dest = 'yes' # Assume dest is local by default
rem_user = nil
rem_srv = nil
ssh = nil # if dest is remote, this will be the Net:SSH.start object
#sftp = nil # if dest is remote, this will be the Net:SFTP.start object
dailydir = 'daily'
weeklydir = 'weekly'
monthlydir = 'monthly'
backup_name = "#{source} Daily Backup"
step = 0 # counter used when printing steps
rsync_opts = '-a --one-file-system --delete --delete-excluded' # default rsync options
#rsync_opts += ' -v' if options[:verbose]
options[:excludes].each { |exc| rsync_opts += " --exclude='#{exc}'" }

# Time and Day related variables
time = Time.new
starttime = time.inspect
months = %w(january february march april may june july august september october november december)
weekdays = %w(sunday monday tuesday wednesday thursday friday saturday)
dailydirs = weekdays.map do |day|
  "daily/#{day}"
end
weeklydirs = Array.new # Stores relative path and dir name for the weekly directories
1.upto(4) { |i| weeklydirs << "weekly/week#{i}" }
monthlydirs = months.map do |month|
  "monthly/#{month}"
end

# Process dest to see if hostname and optionally user name are provided
# ex: --dest joeblow@nas-01:/backups/joeblow
if dest =~ /:/
  local_dest = nil # dest is remote
  require 'rubygems'
  require 'net/ssh'
  #require 'net/sftp'
  rem_srv = dest.match(/^(.*):.*$/)[1]
  rem_srv.sub!(/^.*@/, '')
  if dest =~ /@/
    rem_user = dest.match(/(^.*)@(.*):.*$/)[1]
  else
    rem_user = ENV['USER'] 
  end
  dest = dest.match(/^.*:(.*)$/)[1]
  ssh = Net::SSH.start(rem_srv, rem_user)
  #sftp = Net::SFTP.start(rem_srv, rem_user)
end

# create directory method, supports local and remote
def mkdir(dir, ssh)
  if ssh
    # the stat command will result in stderr stream if file doesn't exist
    ssh.exec!("stat #{dir.gsub(/\s+/, '\ ')}") do |ch, stream, data|
      if stream == :stderr # Directory doesn't exist, create it
        puts "\tCreating remote #{dir}"
        ssh.exec!("mkdir #{dir.gsub(/\s+/, '\ ')}") do |ch, stream, data|
          if stream == :stderr
            raise "Failed to create #{dir}:\n   #{data}"
          end
        end
      end
    end
  else
    unless File.directory?(dir)
      puts "\tCreating local #{dir}"  
      Dir.mkdir(dir)
    end
  end
end

# remove directory, supports local and remote
def rmdir(dir, ssh)
  if ssh
    ssh.exec!("stat #{dir.gsub(/\s+/, '\ ')}") do |ch, stream, data|
      unless stream == :stderr # Directory exist, delete it
        puts "\tDeleting remote #{dir}"
        ssh.exec!("rm -rf #{dir.gsub(/\s+/, '\ ')}") do |ch, stream, data|
          if stream == :stderr
            raise "Failed to delete #{dir}:\n   #{data}"
          end
        end
      end
    end
  else
    if File.directory?(dir)
      puts "\tDeleting local #{dir}"  
      FileUtils.rm_rf(dir)
    end
  end
end

# move directory, supports local and remote
def mvdir(src, dest, ssh)
  if ssh
    ssh.exec!("stat #{src.gsub(/\s+/, '\ ')}") do |ch, stream, data|
      unless stream == :stderr # Directory exist, move it
        puts "\t#{src} => #{dest}"
        ssh.exec!("mv #{src.gsub(/\s+/, '\ ')} #{dest.gsub(/\s+/, '\ ')}") do |ch, stream, data|
          if stream == :stderr
            raise "Failed to move #{src}:\n   #{data}"
          end
        end
      end
    end
  else
    if File.directory?(src)
      puts "\t#{src} => #{dest}"  
      FileUtils.mv(src, dest)
    end
  end
end

# Create symlink to latest snapshot
def soft_link(dir, link, ssh)
  if ssh
    # Can't get "ln -sf" to consistently remove old link, so manually removing it first
    ssh.exec!("if [ -L #{link.gsub(/\s+/, '\ ')} ]; then rm #{link.gsub(/\s+/, '\ ')}; fi")
    ssh.exec!("ln -sf #{dir} #{link.gsub(/\s+/, '\ ')}") do |ch, stream, data|
      if stream == :stderr
        warn "\tFailed to create symlink: #{link}"
      end
    end
  else
    File.unlink(link) if File.symlink?(link)
    File.symlink(dir, link)
  end
end

# call this method like this to support spaces in the path
# disk_free(dest.gsub(/\s+/, '\ '), ssh)
def disk_free(path, ssh)
  cmd = "df -Ph #{path.gsub(/\s+/, '\ ')} | grep -vi ^filesystem | awk '{print \$3 \" of \" \$2}'"
  if ssh
    result = ssh.exec!(cmd)
    result.chomp
  else
    %x[#{cmd}].chomp
  end
end

def hard_link(src, dest, ssh)
  if ssh
    #result = ssh.exec!("cp -al #{src} #{dest}")
    ssh.exec!("cp -al #{src.gsub(/\s+/, '\ ')} #{dest.gsub(/\s+/, '\ ')}") do |ch, stream, data|
      raise "Hard link copy failed #{src} => #{dest}:\n  #{data}" if stream == :stderr
    end
  else
    system("cp -al #{src.gsub(/\s+/, '\ ')} #{dest.gsub(/\s+/, '\ ')}")
    raise "Hard link copy failed #{src} => #{dest}:\n  #{$?.exitstatus}" if $?.exitstatus != 0
  end
end

# rsync method
def run_rsync(opts, src, dest, ssh)
  puts "\trsync #{opts} #{src.gsub(/\s+/, '\ ')} #{dest.gsub(/\s+/, '\ ')}"
  system("rsync #{opts} #{src.gsub(/\s+/, '\ ')} #{dest.gsub(/\s+/, '\ ')}")
  raise "Rsync failed to sync: " if $?.exitstatus != 0
end

# updates the mtime of dest to current time
def update_mtime(dest, ssh)
  if ssh
    ssh.exec!("/bin/touch #{dest.gsub(/\s+/, '\ ')}")
  else
    system("/bin/touch #{dest.gsub(/\s+/, '\ ')}")
  end
end

# escape any spaces in the path before sending it to the df system command
du_pre = disk_free(dest.gsub(/\s+/, '\ '), ssh) # Store disk usage prior to running backup

print <<EOF
======================== BACKUP REPORT ==============================
|  Date          -  #{starttime}
|  Run by        -  #{ENV['USER']}
|  Host          -  #{ENV['HOSTNAME']}
|  Source        -  #{source}
|  Destination   -  #{dest}
EOF
puts "|  Remote User   -  #{rem_user}" if rem_user
puts "|  Remote Server -  #{rem_srv}" if rem_srv
print <<EOF
|   
|  Disk Usage Before Backup: #{du_pre}
=====================================================================
EOF

# Create the base level directory tree
puts "#{step += 1}. Checking for missing base level directories"
for dir in %w(daily weekly monthly)
  mkdir("#{dest}/#{dir}", ssh)
end

# Create daily directories if they don't exist
puts "#{step += 1}. Checking for missing daily snapshot directories"
dailydirs.each do |dir|
  mkdir("#{dest}/#{dir}", ssh)
end

# Delete current days snapshot (should be a week old by now)
puts "#{step += 1}. Removing old daily snapshot"
rmdir("#{dest}/#{dailydirs[time.wday]}", ssh)

# Create hard link copy of yesterday's snapshot to today's directory
puts "#{step += 1}. Creating a hard linked snapshot as the base of today's incremental backup:"
puts "\t#{dailydirs[time.wday - 1]} => #{dailydirs[time.wday]}"
# using full paths will allow the command to work for local and remote destinations
hard_link("#{dest}/#{dailydirs[time.wday - 1]}", "#{dest}/#{dailydirs[time.wday]}", ssh)

# Backup the source using Rsync into today's snapshot directory, end result
# only changed files will consume new disk space in the daily snapshot
# unchanged files will remain hard links
puts "#{step += 1}. Running the rsync command using:"
# use full_dest instead of dest since it will contain user, server and path if dest is remote
run_rsync("#{rsync_opts}", "#{source}", "#{full_dest}/#{dailydirs[time.wday]}", ssh)

# Update the mtime on the current snapshot directory
puts "#{step += 1}. Updating the mtime on #{dest}/#{dailydirs[time.wday]}"
update_mtime("#{dest}/#{dailydirs[time.wday]}", ssh)

# Create a symlink "latest" pointing to the current snapshot
# so that the most current backup can be accessed using a common name
puts "#{step += 1}. Creating symbolic link pointing 'latest' to '#{dailydirs[time.wday]}'"
soft_link("#{dailydirs[time.wday]}", "#{dest}/latest", ssh)

# If it's Sunday, create a snapshot into weekly/weekly1
if time.wday == 0
  substep = 0
  puts "#{step += 1}. Creating weekly snapshot"
  puts "  #{step}.#{substep += 1}. Checking for missing weekly directories"
  weeklydirs.each do |dir|
    mkdir("#{dest}/#{dir}", ssh)
  end
  puts "  #{step}.#{substep += 1}. Removing oldest weekly snapshot"
  rmdir("#{dest}/#{weeklydirs[-1]}", ssh)
  puts "  #{step}.#{substep += 1}. Rotating weekly snapshot directories"
  i = weeklydirs.size - 2 # minus 1 is index of last element, we want 2nd to last
  while i >= 0
    # i.e. say weekly4 is last (deleted in prev step), move weekly3 => weekly4
    # weekly2 => weekly3, weekly1 => weekly2
    mvdir("#{dest}/#{weeklydirs[i]}", "#{dest}/#{weeklydirs[i + 1]}", ssh)
    i -= 1
  end
  puts "  #{step}.#{substep += 1}. Snapshotting #{dailydirs[time.wday - 1]} => #{weeklydirs[0]}"
  hard_link("#{dest}/#{dailydirs[time.wday - 1]}", "#{dest}/#{weeklydirs[0]}", ssh)
else
  puts "#{step += 1}. Weekly snapshot is only created on Sunday, skipping"
end

# If it's the first day of the month, create the monthly/<month name> snapshot
if time.day == 1
  substep = 0
  # subtract 2 from time.month since monthdirs is 0 based and we want last month, not current
  puts "#{step += 1}. Creating monthly snapshot for #{months[time.month - 2]}"
  puts "  #{step}.#{substep += 1}. Checking for missing monthly directories"
  monthlydirs.each do |dir|
      puts " DEBUG:\tEvaluating #{dir}" if debug
      puts "\tmkdir(\"#{dest}/#{dir}\", ssh)" if debug
    mkdir("#{dest}/#{dir}", ssh)
  end
  puts "  #{step}.#{substep += 1}. Removing prior snapshot for last month: #{monthlydirs[time.month - 2]}"
    puts "DEBUG:\trmdir(\"#{dest}/#{monthlydirs[time.month - 2]}\", ssh)" if debug
  rmdir("#{dest}/#{monthlydirs[time.month - 2]}", ssh)
  puts "  #{step}.#{substep += 1}. Snapshotting #{dailydirs[time.wday - 1]} => #{monthlydirs[time.month - 2]}"
    puts "DEBUG:\thard_link(\"#{dest}/#{dailydirs[time.wday - 1]}\", \"#{dest}/#{monthlydirs[time.month - 2]}\", ssh)" if debug
  hard_link("#{dest}/#{dailydirs[time.wday - 1]}", "#{dest}/#{monthlydirs[time.month - 2]}", ssh)
else
  puts "#{step += 1}. Monthly snapshot is only created on the first day of the month, skipping"
end

du_post = disk_free(dest.gsub(/\s+/, '\ '), ssh) # du post running the backup
time2 = Time.new
print <<EOF
============================= SUMMARY ===============================
|  The Disk Usage for the backup device before and after the run
|  Before: #{du_pre}
|  After:  #{du_post}
|
|  Script Started:  #{starttime}
|  Script Finished: #{time2.inspect}
=====================================================================
EOF

unless local_dest
  ssh.close
  #sftp.close
end
