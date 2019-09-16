sitar - simple incremental TAR backups to Amazon S3
===================================================

Welcome to sitar, a simple program to create incremental backups on
Amazon S3 using tar(1).


Features
--------

* Incremental backups - after a full backup, sitar backs up only
  changed files. That means faster backups, less bandwidth used for
  saving backups, and less space used by your S3 buckets.

* Standards compatibility - sitar uses GNU tar(1) for all
  backups. This allows you to use the tools you are already familiar
  with to manage your backups. To restore a backup all you need is to
  download the files from S3, and "untar" them. You do not even need
  sitar to restore.

* Stream directly to S3 - you do not need to have disk space for
  temporary backup files, since the data is streamed directly into S3
  files.

* Level resetting - sitar allows you to reset your next backup levels
  at any time for maximum control of incremental size/time vs faster
  restores.


Requirements
------------

* GNU tar

* [AWS CLI](https://aws.amazon.com/cli/) properly installed and
  configured


WARNING
-------

This program is still in beta stage. Please test your backups
carefully before deploying to production. Use at your own risk.


Installation
============

Run the following commands to install sitar in your system:

```console
sudo wget -q -O /usr/local/bin/sitar https://raw.githubusercontent.com/flaviovs/sitar/master/sitar.sh
sudo chmod +x /usr/local/bin/sitar
```


Usage
=====

Before using sitar, you must ensure that you have AWS CLI properly
installed and configured.  You can check if AWS CLI is installed and
configured by issuing the following command:

```console
aws s3 ls
```

You should see a list of all your S3 buckets. Check
https://aws.amazon.com/cli/ for more details about installing and
configuring AWS CLI.

Command line usage
------------------

_sitar [-C COMPRESS] DIRECTORY s3://BUCKET/PATH/... [EXTRA-TAR-OPTIONS]_

* _COMPRESS_ - specify the compression method for the backups. Can be
  one of _gzip_, _bzip2_, _xz_, or _none_. If not specified, _bzip2_
  will be selected if bzip2(1) is available, otherwise _gzip_.

* _DIRECTORY_ - the directory you want to backup.

* _s3://BUCKET/PATH/..._ - n bucket and object path in S3 where backup
  files should be saved to.

* _EXTRA-TAR-OPTIONS_ - extra options to be passed to
  tar(1). **IMPORTANT:** some tar(1) options can confuse sitar very
  hard. For example, using _--xz_ when sitar thinks you want a
  bzip2(1) backup will probably cause trouble. Generally _--ignore*_
  and/or options that do not change paths or compression methods are
  safe.

Example command line:

```console
sitar / s3://my-bucket/backups --exclude-backups --exclude-vcs-ignores
```

The command above will backup your entire directory hierarchy to the
path _/backups_ in the S3 bucket _my-bucket_. The tar(1) command will
receive the parameters _--exclude-backups --exclude-vcs-ignores_ (the
tar(1) for more information about tar options).


Ignoring files
==============

sitar provides two mechanisms to ignore files:

* _.sitarignore_ - sitar makes tar(1) read glob patterns from
  `.sitarignore` files encountered while backing up, and ignore files
  matching the patterns. For example, the following `/.sitarignore`
  file will ignore some system directories:

        ./mnt
        ./proc
        ./run
        ./sys

* _.sitarskip_ - `.sitarskip` files make tar(1) completely skip all
  files and directory at or below directory containing them. For
  example, to avoid backups of `/var/tmp`, you can do:

	 ```console
	 touch /var/tmp/.sitarskip
	 ```

  **Note:** GNU tar (as of 1.30) will emit a warning for each
  `.sitarskip` file it encounters while doing backups.


Resetting levels
================

sitar will keep incrementing backup levels indefinitely so that new
backups only contain data about files created/updated/deleted since
the last operation. This is optimal from a S3 space and bandwidth
perspective, but having lots of incremental backups can be problematic:

* Backup levels keep track of file deletion using tar(1) snapshots _in
  the next level_. That means that your deleted files will stay on S3
  as long as the current backup level is higher that the one used to
  back up the file.  Also, deleted files need to be "restored" and
  then removed during a full restore, which might make the operation
  significantly slower.

  For example, suppose that a file `large.zip` is backed up on
  level 5. On the next day the file is deleted, so it is not included
  in the next (level 6) daily backup. In this scenario, `large.zip`
  will _still_ be present on your S3 backup, technically
  forever. Moreover, if you need to do a full restore, the backup file
  containing `large.zip` will need to be downloaded and unpacked
  (i.e. you will need the disk space), _even though the file will not
  be present when you finish the full restore_.

* Since you need all incremental backups to restore, the more files
  you have, the more data you need to download during a restore, and
  the more files you will need to process to restore.

To allow you to control your backup levels and avoid any potential
issues, sitar allow you to reset backup level for subsequent backups.

To do that, just save a file named _SITAR-RESET.txt_ in the backup
path on S3. The file should contain a single line containing the
number of the backup level you want to reset to.

For example, to reset to level 3, you can use the fallowing AWS CLI
command:

```console
echo 3 | aws s3 cp - s3://my-bucket/path/SITAR-RESET.txt
```

The number specified in the _SITAR-RESET.txt_ tells sitar which level
should be considered the current backup level during the _next
backup_. The program will delete all obsolete backups after resetting
the level.

Note that sitar reset the _current_ backup level. If you reset to _0_
you will effectively delete all your incremental files -- incremental
backups will then start over. Also note that the reset mechanism is
not meant to reset a _full_ backup. To do that, you just rename/remove
the backup path in S3 and re-run sitar.


How it woks
===========

The program firstly does a full backup using tar(1), and incremental
backups after that.

During the first backup, all files are backed up and saved in a file
named _full.tar.bz2_ (or _full.tar.gz_, if bzip(1) is not available)
on the provided S3 path. A tar(1) snapshot is generated and archived
(among other information) in a _.sitar_ file, which is also uploaded
to the backup path in S3.

Subsequent backups are done by fetching the _.sitar_ file and using
previous tar(1) snapshots to configure the next backup
level. Incremental backups are saved in files named
_inc-SEQUENCE-LEVEL.tar.*_ where:

* _SEQUENCE_ - is the incremental backup sequence number. Incremental
  backups should be restored in the right sequence, and the _SEQUENCE_
  number can be used to ensure the right ordering.

* _LEVEL_ - is the level of the incremental backup. Informative only,
  can be useful in disaster recovery situations, in case someone mess
  up with backup files.

After an incremental backup is finished, the _.sitar_ file is updated
and uploaded to S3.

A _README.txt_ file is also created with basic instruction for
restoring the backup.

**IMPORTANT:** do not delete the _.sitar_ file present on your S3
backup path. Your current backup will not be affected, but the program
will refuse to do new backups if you do this.


Restoring a backup
==================

1. Download the _full.tar.bz2_ file and **all** _inc-*_ files. This can
   be accomplished with the following AWS CLI command:

   ```console
   aws s3 cp --exclude=.sitar --recursive s3://my-bucket/path .
   ```

1. Restore the full backup:

   ```console
   tar xf full.tar.bz2 --bzip2 --listed-incremental=/dev/null -C /tmp/restore
   ```

4. Restore all incremental backups:

   ```console
   LC_ALL=C ls inc-* | while read file; do \
     tar xf "$file" --bzip2 --listed-incremental=/dev/null -C /tmp/restore; done
   ```

Notes:

* The examples assume that you used bzip2(1) for your backups. For
  gzip(1) or wx(1) (or uncompressed) backups, you must adjust options
  and file names accordingly.

* You will need to restore incremental backups manually if you
  switched compression method after having some incremental backups
  already done, since your _inc-*_ files will have different
  extensions/compression methods. The "for loop" above **will not
  work** if your incremental backups have mixed compression methods.

* Do not forget the _--listed-incremental=/dev/null_ option. Your
  backup will not restore correctly if you omit it.


Customizing AWS CLI
===================

Use the _AWS_ environment variable to customize the location of the
AWS CLI executable:

```console
AWS="$HOME/bin/aws" sitar / s3://my-bucket/path
```


You can also use the _AWSCLI_EXTRA_ environment variable to pass extra
options to the AWS CLI command used to push backup data to S3. For
example, to use the _Standard IA_ storage class for your backups by
default, you can use the following:

```console
AWSCLI_EXTRA="--storage-class=STANDARD_IA" sitar / s3://my-bucket/path
```

Known issues
============

* Streaming to S3 will fail if a single backup file is larger than
  5GB. To workaround this, use the _AWSCLI_EXTRA_ environment variable
  (see above) to pass _--expected-size=SIZE_ to AWS CLI, where _SIZE_
  is a rough estimation of your backup size (it just need to be a
  little bigger than the data being uploaded). See
  https://docs.aws.amazon.com/cli/latest/reference/s3/cp.html for more
  details.

* sitar does not do any locking of backup paths in S3. Make sure you
  are not running two or more backups pointing to the same S3 paths,
  otherwise bad things will happen to your data.


Bugs? Suggestions?
==================

https://github.com/flaviovs/sitar
