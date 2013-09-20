#!/usr/bin/ruby
##!/usr/bin/ruby -w
#-----------------------------------------------------------------------------
# Name        :  ghetto-timemachine.rb
# Author      :  Mike Hanby < mhanby at uab.edu >
# Organization:  University of Alabama at Birmingham IT Research Computing
# Description :  This script is used for backing up a *NIX workstation using the
#     classic Rsync using Hardlinks rotation technique described at this URL:
#     http://www.mikerubel.org/computers/rsync_snapshots/ 
#                 
# Usage       :  $0 --src ~/Documents --dest /backups/userA --excludes \*.iso,.svn
# Date        :  2012-03-20 10:30:19
# Type        :  Utility
# License     :  Apache License, Version 2.0 - http://www.apache.org/licenses/LICENSE-2.0.html
#
# Examples
#   1.  This example is a cron job that uses pre and post commands to suspend
#       VirtualBox guests during the backup (note, the command has been split onto
#       multiple lines for readability)
#   10 1 * * * /usr/local/bin/ghetto-timemachine.rb --src /home/mhanby \
#   --dest nas-srv1:/data/mhanby/backups/workstation \
#   --excludes=tmp/\*,Downloads/\*,archive/\*,lost+found,VirtualBox\ VMs/\*/Snapshots \
#   --precmds '/usr/bin/VBoxManage list runningvms > /var/tmp/runningvms.log',"/usr/bin/awk '{ print \$1; system(\"/usr/bin/VBoxManage controlvm \" \$1 \" savestate\") }' /var/tmp/runningvms.log" \
#   --postcmds "/usr/bin/awk '{ print \$1; system(\"/usr/bin/VBoxManage startvm \" \$1) }' /var/tmp/runningvms.log","rm /var/tmp/runningvms.log" \
#   | mail -s "SNAPSHOT - Home Directory on $(hostname -s)" mhanby
#
#   2.  Backup a remote server (multiple directories) to local file system.
#   /usr/local/bin/ghetto-timemachine.rb -j "Backup of nagios.mydom.com" \
#   --src nagios.mydom.com:/boot,/etc,/home,/opt,/root,/usr,/var \
#   --dest /data/backup/nagios.mydom.com
#
#-----------------------------------------------------------------------------
# History
# TODO: Restructured the script putting the methods into a class and the runtime
#     code into an "if __FILE__ == $0" statement to allow the class to be loaded
#     by other scripts, and allow the script to run standalone
# 20130919 - mhanby - v1.0.19
#   - Added error handling to mkdir, rmdir, mvdir and soft_link for non-ssh backups. Error
#     handling already existed for ssh based backups. This should address the issue
#     identified below
#   - Identified a bug where FileUtils.rm_rf was failing due to a permissions problem. The failure wasn't trapped
#     and resulted in a directory recursion that would keep compounding over time (thus eating up disk space and inodes)
#
#     Resulting in this kind of tree
#       sunday
#          mhanby
#          saturday
#       monday
#          mhanby
#          sunday
#       tuesday
#          mhanby
#          monday
# ...
# 20130221 - mhanby - v1.0.18
#   - Added a license to the project
#     Apache License, Version 2.0 - http://www.apache.org/licenses/LICENSE-2.0.html
# 20121211 - mhanby - v1.0.17
#   - Fixed bug when remote source contained multiple sources, the code now
#     wraps the source list in single quotes so that rsync treats it as a list
#     wrather than multiple arguments. 
# 20120621 - mhanby - v1.0.16
#   - Added a new array of protected destinations, if --dest matches one of these
#     the script will error out. The intention is to prevent accidentally
#     overwriting root or other special directories (especially since we use
#     rsync option --delete)
#   - Added support for spaces in src and dest paths. Spaces in --src or --dest can
#     be quoted (the full string) or escaped. Ex:
#     --src /home/mhanby/Some\ Dir
#     --src "/home/mhanby/Some Dir"
#   - Added support for multiple source directories by converting the --src option
#     to an Array. Example of usage:
#     --src /home/mhanby/dir1,/home/mhanby/dir2,home/mhanby/Some\ Dir
#   - Added two new arguments:
#     --jobdesc - this arg takes a string description of the job. This is used for
#       the report header. If it's left off, a default description will be used
#     --override - this overrides the safey check preventing --precmds and --postcmds
#       from being used when the script is run as root.
# 20120620 - mhanby - v1.0.15
#   - Script now supports remote src or dest, errors if both are remote
#   - Now verifies that both source and dest exist before proceeding, previously
#     only verified destination
# 20120507 - mhanby - The following error was thrown by rsync, resulting in the
#   job to stop processing, due to this code:
#     raise "Rsync failed to sync: " if $?.exitstatus != 0)
#   Rsync Error
#     file has vanished: "~/.config/google-chrome/Default/Cookies-journal"
#     rsync warning: some files vanished before they could be transferred
#     (code 24) at main.c(1052) [sender=3.0.8]
#     ~/scripts/ghetto-timemachine/lib/ghetto-timemachine.rb:360:in `run_rsync':
#     Rsync failed to sync:  (RuntimeError)
#   Should this be fatal in the script, or a warn?
# 20120430 - mhanby - Fixed a major bug in mvdir() method where local dir moves
#   would not execute if the src dir existed. Remote execution (ssh) worked properly
# 20120409 - mhanby - Fixed reporting string for post command exectution, was reporting
#   "pre" not "post"
# 20120403 - mhanby - Fixed logic bug in code that checks if user is root
# 20120403 - mhanby - Added new features
#   1. --precmds  - A comma separated list of commands to run prior to the backup
#   2. --postcmds - A comma separated list of commands to run after the backup
#   Surround each commands in quotes that contain spaces
#   Commands must be escaped where neccessary 
#   Example, stopping VirtualBox VMs prior to backup, then resume them:
#  $ ./ghetto-timemachine.rb --src ~ \
#    --dest user1@srv01:/backups/user1 \
#    --precmds '/usr/bin/VBoxManage list runningvms > /var/tmp/runningvms.log',"/usr/bin/awk '{ print \$1; system(\"/usr/bin/VBoxManage controlvm \" \$1 \" savestate\") }' /var/tmp/runningvms.log" \
#    --postcmds "/usr/bin/awk '{ print \$1; system(\"/usr/bin/VBoxManage startvm \" \$1) }' /var/tmp/runningvms.log","rm /var/tmp/runningvms.log"
#
#   The script will error if either of these args are used and the executing user is ROOT
# 20120402 - mhanby - Created new method, chkdir(dir, ssh), used throughout the code
#   to check if dir exists. chkdir works for both local and remote.
#   This consolidates all directory checking code into single method and attempts
#   to solve an issue the script was having with previous remote dir checks, where
#   the results relied on stderr to indicate the absence of the dir. This wasn't
#   100% predictable and led to unpredictable results.
# 20120330 - mhanby - some minor fixes
#   1. script would error if optional --excludes was not provide
#   2. runnign script via cron, the HOSTNAME env variable is not set in the limited
#     cron env, thus #{ENV['HOSTNAME']} returned nothing
#     Now using Socket.gethostname
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
#    * update_mtime(dir, ssh)
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
#      export RUBYVER=`ruby --version | cut -d" " -f 2 | cut -d. -f 1,2`
#      export GEM_HOME=$HOME/.ruby/lib/ruby/gems/${RUBYVER}
#      export RUBYLIB=$HOME/.ruby/lib/ruby:$HOME/.ruby/lib/site_ruby/${RUBYVER}:${RUBYLIB}
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
# TODO - Allow for multiple src directories, in the form of --src usr@srv:/src1,/src2,/srcN
# TODO - Add a lock file to prevent the script from running multiple times for the
#   same backup job
#   May add a #{jobname} variable to the job to allow for multiple unrelated backups
#   to run at same time
# FIXED - 3.  Source and Dest with spaces in the path don't currently work.
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
# FIXED - 1.  Figure out a way to allow this script to write to a remote --dest that is
#     accessible via ssh (sftp, rsync -e ssh, etc...)
#-----------------------------------------------------------------------------
require 'rubygems'
require 'optparse' # CLI Option Parser
require 'fileutils' # allow recursive deletion of directory
require 'socket' # For Socket.gethostname

@@VERSION = '1.0.19'
copywrite = "Copyright (c) 2012 Mike Hanby, University of Alabama at Birmingham IT Research Computing."

options = Hash.new # Hash to hold all options parsed from CLI

optparse = OptionParser.new()  do |opts|
  # Help screen banner
  opts.banner = "#{copywrite}
  
  #{File.basename("#{$0}")} - version #{@@VERSION}
  
  Backs up the provided SRC to DEST using rsync and hardlinks to provide
  an incremental backup solution without duplicating consumption of storage
  for unmodified files.

  Usage: #{File.basename("#{$0}")} [options] --src PATH --dest PATH"
  
  # Define the options and what they do
  # debug
  options[:debug] = nil
  opts.on('-v', '--debug', 'Script Debugging Output') do
    options[:debug] = true
  end

  # override the "cannot run pre/post commands as root" protection
  options[:override] = nil
  opts.on('--override', 'Override the protection mechanism that prevents the use of
             --precmds and --postcmds when running as root. Be careful!') do
    options[:override] = true
  end

  # Backup Name
  options[:jobdesc] = nil
  opts.on('-j', '--jobdesc "Job Description"', 'Description for this backup job') do |jobdesc|
    options[:jobdesc] = jobdesc
  end

  # source director(ies)
  options[:sources] = nil
  # opts.on('-s', '--src', '--source FILE', 'Local source directory') do |src|
  opts.on('-s', '--src', '--sources Dir1,Dir2,DirN', Array, 'Local source director(ies), comma separated and no spaces!') do |src|
    options[:sources] = src
  end

  # destination directory
  options[:dest] = nil
  opts.on('-d', '--dst', '--dest FILE', 'Local or remote destination directory\nFor remote use syntax: user@host:/PATH') do |dst|
    options[:dest] = dst
  end

  # Files or directories to exclude
  options[:excludes] = nil
  opts.on('-e', '--excludes Patrn1,Patrn2,PatrnN', Array, 'Can specify multiple patterns to exclude separated by commas.
            See man rsync for PATTERN details') do |exc|
    options[:excludes] = exc
  end

  # Commands to run prior to backup
  options[:precmds] = nil
  opts.on('--precmds Cmd1,Cmd2,CmdN', Array, 'Can specify multiple system commands that will execute locally prior to the backup
             NOTE: make sure to wrap cmdN in quotes if it has spaces, and escape where appropriate
             WARNING: This can be dangerous, double check command syntax and make sure you know what you are doing!') do |pre|
    options[:precmds] = pre
  end

  # Commands to run after the backup
  options[:postcmds] = nil
  opts.on('--postcmds Cmd1,Cmd2,CmdN', Array, 'Can specify multiple system commands that will execute locally after the backup
             NOTE: make sure to wrap cmdN in quotes if it has spaces, and escape where appropriate
             WARNING: This can be dangerous, double check command syntax and make sure you know what you are doing!') do |post|
    options[:postcmds] = post
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

raise "\nMandatory argument --src is missing, see --help for details\n" if options[:sources].nil?
raise "\nMandatory argument --dest is missing, see --help for details\n" if options[:dest].nil?
raise "\nBoth of the arguments, --src and --dst, cannot be remote.\nOnly one remote location is supported, the other must be local!\n" if options[:sources] =~ /:/ && options[:dest] =~ /:/

# variables
debug = options[:debug]
sources = options[:sources]
dest = options[:dest] # will get trimmed to only include the path
full_src = '' # this var will contain full unaltered source, including user, srv, and all sources
full_dest = dest # this var will contain full unaltered dest, including user, srv, path
remote_user = nil
remote_srv = nil
ssh_src = nil # if source is remote, this will be the Net:SSH.start object
ssh_dest = nil # if dest is remote, this will be the Net:SSH.start object
dailydir = 'daily'
weeklydir = 'weekly'
monthlydir = 'monthly'
basedirs = [dailydir, weeklydir, monthlydir]
backup_name = ''
step = 0 # counter used when printing steps
rsync_opts = '-a --one-file-system --delete --delete-excluded' # default rsync options
#rsync_opts += ' -v' if options[:verbose]
options[:excludes].each { |exc| rsync_opts += " --exclude='#{exc}'" } if options[:excludes]
precmds = nil
precmds = options[:precmds] if options[:precmds] 
postcmds = nil
postcmds = options[:postcmds] if options[:postcmds]

if ( precmds || postcmds ) && ( Process.uid == 0 && options[:override].nil? )
#  puts "root user: euid: #{Process.euid} uid: #{Process.uid}"
  raise "For protection, the script doesn't allow use of --precmds or --postcmds if run as user ROOT"
end

# Protected destinations, script will error if dest points to one of these
protected_dests = %w(/ /boot /dev /etc /proc /sys /home /root /var /bin /lib /lib64 /usr/lib /usr/lib64 /usr/bin /usr/sbin /usr/etc  )

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

# Process sources and dest to see if hostname and optionally user name are provided
# in either.
# ex: --dest joeblow@nas-01:/backups/joeblow
if sources[0] =~ /:/
  require 'rubygems'
  require 'net/ssh'
  remote_srv = sources[0].match(/^(.*):.*$/)[1]
  remote_srv.sub!(/^.*@/, '')
  if sources[0] =~ /@/
    remote_user = sources[0].match(/(^.*)@(.*):.*$/)[1]
  else
    remote_user = ENV['USER'] 
  end
  # Strip out the user and server part of the string
  sources[0] = sources[0].match(/^.*:(.*)$/)[1]
  full_src << "#{remote_user}@" if remote_user
  full_src << "#{remote_srv}:" if remote_srv
  ssh_src = Net::SSH.start(remote_srv, remote_user)
elsif dest =~ /:/
  # remote_dst = 'yes'
  require 'rubygems'
  require 'net/ssh'
  remote_srv = dest.match(/^(.*):.*$/)[1]
  remote_srv.sub!(/^.*@/, '')
  if dest =~ /@/
    remote_user = dest.match(/(^.*)@(.*):.*$/)[1]
  else
    remote_user = ENV['USER'] 
  end
  # Strip out the user and server part of the string
  dest = dest.match(/^.*:(.*)$/)[1]
  ssh_dest = Net::SSH.start(remote_srv, remote_user)
end

# escape spaces in dest
dest.gsub!(/\s+/, '\ ')

# escape spaces in the source dirs
sources.map!{ |src| src.gsub(/[\s]+/, '\ ')}

# wrap source directories in single quotes if source is remote and source list contains multiple directories
if sources.size > 1
  #full_src << "'" if [ssh_src,ssh_dest]
  full_src << "'" if ssh_src
  sources.each do |src|
    full_src << "#{src} "
  end
  full_src.strip!
  #full_src << "'" if [ssh_src,ssh_dest]
  full_src << "'" if ssh_src
else
  full_src << sources[0]
end

# Verify that dest isn't one of the protected destinations
raise "\nDestination #{dest} matches one of the protected destinations in #{protected_dests}\n" if protected_dests.include? dest

backup_name = options[:jobdesc].nil? ? "#{full_src} Daily Backup" : options[:jobdesc]

# Check whether or not a local or remote directory exists
def chkdir(dir, ssh)
  result = nil
  if ssh
    # BASH test for directory
    result = ssh.exec!("[ -d #{dir} ] && echo exists")
  else
    result = 'exists' if File.directory?(dir.gsub(/\\\s+/, ' ')) # ruby method doesn't work with spaces escaped
  end
  return result
end

# create directory method, supports local and remote
def mkdir(dir, ssh)
  unless chkdir(dir, ssh)
    if ssh
      puts "\tCreating remote dir #{dir}"
      ssh.exec!("mkdir #{dir}") do |ch, stream, data|
        if stream == :stderr
          raise "Failed to create #{dir}:\n   #{data}"
        end
      end
    else
      dir_spc = dir.gsub(/\\\s+/, ' ') # Dir.* methods doen't work with spaces escaped, "unescape them"
      puts "\tCreating local dir #{dir_spc}"
      Dir.mkdir(dir_spc)
      raise "Failed to create #{dir_spc}" if !File.directory?(dir_spc)
    end
  end
end

# remove directory, supports local and remote
def rmdir(dir, ssh)
  if chkdir(dir, ssh) # dir exists, delete it
    if ssh
      puts "\tDeleting remote dir #{dir}"
      ssh.exec!("rm -rf #{dir}") do |ch, stream, data|
        if stream == :stderr
          raise "Failed to delete #{dir}:\n   #{data}"
        end
      end
    else
      dir_spc = dir.gsub(/\\\s+/, ' ') # FileUtils.* methods doen't work with spaces escaped, "unescape them"
      puts "\tDeleting local dir #{dir_spc}"
      FileUtils.rm_rf(dir_spc, :secure=>true)
      raise "Failed to completely remove destination directory: #{dir_spc}" if File.directory?(dir_spc)
    end
  end
end

# move directory, supports local and remote
def mvdir(src, dest, ssh)
  if chkdir(src, ssh) # source dir exists, move it
    if ssh
      puts "\t#{src} => #{dest}"
      ssh.exec!("mv #{src} #{dest}") do |ch, stream, data|
        if stream == :stderr
          raise "Failed to move #{src} to #{dest}:\n   #{data}"
        end
      end
    else
      src_spc = src.gsub(/\\\s+/, ' ')
      dest_spc = dest.gsub(/\\\s+/, ' ')
      puts "\t#{src} => #{dest}"
      FileUtils.mv(src_spc, dest_spc) # FileUtils.* methods doen't work with spaces escaped, "unescape them"
      raise "Failed to move #{src_spc} to #{dest_spc}" if !File.directory?(dest_spc)
    end
  end
end

# Create symlink to latest snapshot
def soft_link(dir, link, ssh)
  if ssh
    # Can't get "ln -sf" to consistently remove old link, so manually removing it first
    ssh.exec!("if [ -L #{link} ]; then rm #{link}; fi")
    ssh.exec!("ln -sf #{dir} #{link}") do |ch, stream, data|
      if stream == :stderr
        warn "\tFailed to create symlink: #{link}"
      end
    end
  else
    dir_spc = dir.gsub(/\\\s+/, ' ')
    link_spc = link.gsub(/\\\s+/, ' ')
    File.unlink(link_spc) if File.symlink?(link_spc)
    File.symlink(dir_spc, link_spc)
    warn "\tFailed to create symlink: #{link_spc}" if !File.symlink?(link_spc)
  end
end

# call this method like this to support spaces in the path
# disk_free(dest.gsub(/\s+/, '\ '), ssh)
def disk_free(path, ssh)
  cmd = "df -Ph #{path} | grep -vi ^filesystem | awk '{print \$3 \" of \" \$2}'"
  if ssh
    result = ssh.exec!(cmd)
    result.chomp
  else
    %x[#{cmd}].chomp
  end
end

# Create hardlink copy of src to dest
def hard_link(src, dest, ssh)
  if ssh
    ssh.exec!("cp -al #{src} #{dest}") do |ch, stream, data|
      raise "Hard link copy failed #{src} => #{dest}:\n  #{data}" if stream == :stderr
    end
  else
    #puts "DEBUG: cp -al #{src} #{dest}"
    system("cp -al #{src} #{dest}")
    raise "Hard link copy failed #{src} => #{dest}:\n  #{$?.exitstatus}" if $?.exitstatus != 0
  end
end

# rsync method
def run_rsync(opts, src, dest, ssh_src, ssh_dest)
  puts "\trsync #{opts} #{src} #{dest}"
  system("rsync #{opts} #{src} #{dest}")
  raise "Rsync failed to sync: " if $?.exitstatus != 0
end

# updates the mtime of dest to current time
def update_mtime(dir, ssh)
  if ssh
    ssh.exec!("/bin/touch #{dir}")
  else
    system("/bin/touch #{dir}")
  end
end

# Execut pre backup commands
def exec_cmds(cmds)
  # Is it safe to allow the user to pass commands into the script and
  # run them via system without using parameters?
  cmds.each do |cmd|
    puts "\tExecuting:\n\t  #{cmd}"
    system(cmd)
    raise "System command failed: #{$?}" if $? != 0
  end  
end

# Exit the script after fatal error
# Not implemented yet, still have some work to do
def exit_fatal(msg, postcmds)
  # Exit the script, but first run post commands
  puts "Fatal Error Reported, beginning exit procedure"
  if postcmds
    puts "  Running Post system commands prior to exitting:"
    exec_cmds(postcmds)
  else
    puts "  No Post backup system commands specified, continuing exitting after fatal error"
  end
  raise "#{msg}"
end

# escape any spaces in the path before sending it to the df system command
du_pre = disk_free(dest, ssh_dest) # Store disk usage prior to running backup

print <<EOF
======================== BACKUP REPORT ==============================
|  Description   -  #{backup_name}
|  Date          -  #{starttime}
|  Run by        -  #{ENV['USER']}
|  Host          -  #{Socket.gethostname}
|  Source Directories:
EOF
sources.each do |src|
  puts "\t\t\t#{src}"
end
print <<EOF
|  Destination   -  #{dest}
EOF
puts "|  Remote User   -  #{remote_user}" if remote_user
puts "|  Remote Server -  #{remote_srv}" if remote_srv
print <<EOF
|   
|  Disk Usage Before Backup: #{du_pre}
=====================================================================
EOF

# Check if the base destination directory exists
puts "#{step += 1}. Checking for base source and destination director(ies)"
# source director(ies) check
sources.each do |src|
  unless chkdir(src, ssh_src)
    raise "Source dir does not exist: #{src}"
  end
end
# Destination check
unless chkdir(dest, ssh_dest)
  raise "Destination dir does not exist: #{dest}"
end

# Run the pre backup system command
if precmds
  puts "#{step += 1}. Executing Pre backup system commands on the local host"
  exec_cmds(precmds)
else
  puts "#{step += 1}. No Pre backup system commands specified, skipping"
end

# Create the base level directory tree
puts "#{step += 1}. Checking for missing base level destination directories"
basedirs.each do |dir|
  mkdir("#{dest}/#{dir}", ssh_dest)
end

# Create daily directories if they don't exist
puts "#{step += 1}. Checking for missing daily snapshot destination directories"
dailydirs.each do |dir|
  mkdir("#{dest}/#{dir}", ssh_dest)
end

# Delete current days snapshot (should be a week old by now)
puts "#{step += 1}. Removing old daily snapshot"
rmdir("#{dest}/#{dailydirs[time.wday]}", ssh_dest)

# Create hard link copy of yesterday's snapshot to today's directory
puts "#{step += 1}. Creating a hard linked snapshot as the base of today's incremental backup:"
puts "\t#{dailydirs[time.wday - 1]} => #{dailydirs[time.wday]}"
# using full paths will allow the command to work for local and remote destinations
hard_link("#{dest}/#{dailydirs[time.wday - 1]}", "#{dest}/#{dailydirs[time.wday]}", ssh_dest)

# Backup the source using Rsync into today's snapshot directory, end result
# only changed files will consume new disk space in the daily snapshot
# unchanged files will remain hard links
puts "#{step += 1}. Running the rsync command using:"
# use full_dest instead of dest since it will contain user, server and path if dest is remote
run_rsync("#{rsync_opts}", "#{full_src}", "#{full_dest}/#{dailydirs[time.wday]}", ssh_src, ssh_dest)

# Update the mtime on the current snapshot directory
puts "#{step += 1}. Updating the mtime on #{dest}/#{dailydirs[time.wday]}"
update_mtime("#{dest}/#{dailydirs[time.wday]}", ssh_dest)

# Create a symlink "latest" pointing to the current snapshot
# so that the most current backup can be accessed using a common name
puts "#{step += 1}. Creating symbolic link pointing 'latest' to '#{dailydirs[time.wday]}'"
soft_link("#{dailydirs[time.wday]}", "#{dest}/latest", ssh_dest)

# If it's Sunday, create a snapshot into weekly/weekly1
if time.wday == 0 # first day of week, zero based
  substep = 0
  puts "#{step += 1}. Creating weekly snapshot"
  puts "  #{step}.#{substep += 1}. Checking for missing weekly directories"
  weeklydirs.each do |dir|
    mkdir("#{dest}/#{dir}", ssh_dest)
  end
  puts "  #{step}.#{substep += 1}. Removing oldest weekly snapshot"
  rmdir("#{dest}/#{weeklydirs[-1]}", ssh_dest)
  puts "  #{step}.#{substep += 1}. Rotating weekly snapshot directories"
  i = weeklydirs.size - 2 # Store index of 2nd to last element in weeklydirs
  while i >= 0
    # i.e. say weekly4 is last (deleted in prev step), move weekly3 => weekly4
    # weekly2 => weekly3, weekly1 => weekly2
    mvdir("#{dest}/#{weeklydirs[i]}", "#{dest}/#{weeklydirs[i + 1]}", ssh_dest)
    i -= 1
  end
  puts "  #{step}.#{substep += 1}. Snapshotting #{dailydirs[time.wday - 1]} => #{weeklydirs[0]}"
  hard_link("#{dest}/#{dailydirs[time.wday - 1]}", "#{dest}/#{weeklydirs[0]}", ssh_dest)
else
  puts "#{step += 1}. Weekly snapshot is only created on Sunday, skipping"
end

# If it's the first day of the month, create the monthly/<month name> snapshot
if time.day == 1 # first day of month
  substep = 0
  # subtract 2 from time.month since monthdirs is 0 based and we want last month, not current
  puts "#{step += 1}. Creating monthly snapshot for #{months[time.month - 2]}"
  puts "  #{step}.#{substep += 1}. Checking for missing monthly directories"
  monthlydirs.each do |dir|
      puts " DEBUG:\tEvaluating #{dir}" if debug
      puts "\tmkdir(\"#{dest}/#{dir}\", ssh_dest)" if debug
    mkdir("#{dest}/#{dir}", ssh_dest)
  end
  puts "  #{step}.#{substep += 1}. Removing prior snapshot for last month: #{monthlydirs[time.month - 2]}"
    puts "DEBUG:\trmdir(\"#{dest}/#{monthlydirs[time.month - 2]}\", ssh_dest)" if debug
  rmdir("#{dest}/#{monthlydirs[time.month - 2]}", ssh_dest)
  puts "  #{step}.#{substep += 1}. Snapshotting #{dailydirs[time.wday - 1]} => #{monthlydirs[time.month - 2]}"
    puts "DEBUG:\thard_link(\"#{dest}/#{dailydirs[time.wday - 1]}\", \"#{dest}/#{monthlydirs[time.month - 2]}\", ssh_dest)" if debug
  hard_link("#{dest}/#{dailydirs[time.wday - 1]}", "#{dest}/#{monthlydirs[time.month - 2]}", ssh_dest)
else
  puts "#{step += 1}. Monthly snapshot is only created on the first day of the month, skipping"
end

# Run the post backup system command
if postcmds
  puts "#{step += 1}. Executing Post backup system commands on the local host"
  exec_cmds(postcmds)
else
  puts "#{step += 1}. No Post backup system commands specified, skipping"
end

du_post = disk_free(dest, ssh_dest) # du post running the backup
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

ssh_src.close if ssh_src
ssh_dest.close if ssh_dest

