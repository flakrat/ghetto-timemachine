>  Name: ghetto-timemachine.rb
>  Author:   Mike Hanby
>  Email:    flakrat at yahoo.com
>  Org:      University of Alabama at Birmingham IT Research Computing
>  License:  Apache License, Version 2.0 - http://www.apache.org/licenses/LICENSE-2.0.html

## Description
Disclaimer: This is my first stab at a Ruby script, so tips, fixes, suggestions, whatever are welcome. I'm a sysadmin, not a programmer, so please let me know if there are any style mistakes, odd logic, etc...

The name of the script comes from:
-  ghetto - A highly popular open source backup script for VMware ESX servers is uses ghetto, figured I'd borrow from that
-  timemachine - the end result of the backup is "sort of" like the fruit named tech company's Time Machine

The core functionality of the script comes from:
http://www.mikerubel.org/computers/rsync_snapshots/

The backup creates the following sub directories under the target directory:
-  target
   -  daily
      -  sunday
      -  monday
      -  tuesday
      -  wednesday
      -  thursday
      -  friday
      -  saturday
   -  weekly
      -  week1
      -  week2
      -  week3
      -  week4
   -  monthly
      -  january
      -  february
     .......
      -  december
   -  latest -> symlink to latest daily snapshot

Here's what it does sequentially (assume we are running the script on Thursday, March 8th):
1.  Verifies that the dest exists, if not it errors out
1.  Executes any commands provided by the --precmds cli option
1.  Creates the daily, weekly and monthly directories in $dest
1.  Prints a fancy header :-)
1.  Creates the weekday (monday, tuesday...) named directories under daily if they don't exist
1.  Removes the snapshot (directory) for the current day of the week (dest/daily/thursday)
1.  Creates a hardlinked copy of dest/daily/wednesday to dest/daily/thursday. The two directories are now identical, all files inodes are the same, so disk usage hasn't changed by much
1.  Using the rsync command, src is synced into dest/daily/thursday. The script uses the `--delete` and `--delete-excluded` options to remove anything from the dest that doesn't currently exist in the src
1.  Create a symbolic link dest/latest pointing to dest/daily/thursday, making it easy to access the most recent backup
1.  On Sunday, it will remove the oldest weekly directory (week4), rotate the others (week3 to 4, 2 to 3, 1 to 2), and then create a snapshot of Saturday in weekly/week1
1.  On the first day of every month it will create a snapshot for the previous month based on the previous day snapshot, first removing the existing snapshot for the month, so we only keep 12 months
1.  Executes and commands provided by the `--postcmds` cli option
1.  Print a nice summary

## Example usage:

-  Local source to local destination

```
./ghetto-timemachine.rb --src ~/Pictures --dest /media/USB/backup --excludes \*.raw,\*.bmp
```

-  Local source to remote destination (uses ssh keys)

```
./ghetto-timemachine.rb --src ~/Pictures --dest user@server:/backup --excludes \*.raw,\*.bmp
```

## Cron Job
The following is an example cron job to run the script at 1:10 AM, including PATHs to user supplied Ruby libraries (line breaks added for readability)

```
10 1 -  * -  export GEM_HOME=$HOME/.ruby/lib/ruby/gems/1.8 ; \
export RUBYLIB=$HOME/.ruby/lib:$HOME/.ruby/lib/site_ruby/1.8:$RUBYLIB ; \
$HOME/bin/ghetto-timemachine.rb --src $HOME \
  --dest nas-srv:/backups/user1/workstation \
  --exclude=tmp/\*,Downloads/\*,archive/\*,lost+found \
  | mail -s "SNAPSHOT - Home Directory on $(hostname -s)" flakrat
```

Another example providing pre and post commands to savestate and resume virtual machines:

```
10 1 -  * -  export GEM_HOME=$HOME/.ruby/lib/ruby/gems/1.8 ; \
export RUBYLIB=$HOME/.ruby/lib:$HOME/.ruby/lib/site_ruby/1.8:$RUBYLIB ; \
$HOME/bin/ghetto-timemachine.rb --src $HOME \
  --dest user1@nas-srv:/backups/user1/workstation \
  --exclude=tmp/\*,Downloads/\*,archive/\*,lost+found \
  --precmds '/usr/bin/VBoxManage list runningvms > /var/tmp/runningvms.log',"/usr/bin/awk '{ print \$1; system(\"/usr/bin/VBoxManage controlvm \" \$1 \" savestate\") }' /var/tmp/runningvms.log" \
  --postcmds "/usr/bin/awk '{ print \$1; system(\"/usr/bin/VBoxManage startvm \" \$1) }' /var/tmp/runningvms.log","rm /var/tmp/runningvms.log"
```

Enjoy,

Mike
