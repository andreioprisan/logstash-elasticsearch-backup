#!/bin/bash
# 
# logstash-elasticsearch-backup.sh
#
# Push logstash index from yesterday to s3 with an accompanying restore script.
#   http://logstash.net
#   http://www.elasticsearch.org
#   https://github.com/seedifferently/boto_rsync
#
#   Inspiration: 
#     http://tech.superhappykittymeow.com/?p=296
# 
# Must run on an elasticsearch node, and expects to find the index on this node.

usage()
{
cat << EOF

logstash-elasticsearch-backup.sh

Create a restorable backup of an elasticsearch index (assumes Logstash format
indexes), and upload it to an existing S3 bucket. The default backs up an
index from yesterday. Note that this script itself does not restart 
elasticsearch - the restore script that is generated for each backup will 
restart elasticsearch after restoring an archived index.

USAGE: ./logstash-elasticsearch-backup.sh -b S3_BUCKET -i INDEX_DIRECTORY [OPTIONS]

OPTIONS:
  -h    Show this message
  -b    S3 path for backups (Required)
  -i    Elasticsearch index directory (Required)
  -d    Backup a specific date (format: YYYY.mm.dd)
  -c    Command for BOTOCMD (default: BOTOCMD put)
  -t    Temporary directory for archiving (default: /tmp)
  -p    Persist local backups, by default backups are not kept locally
  -s    Shards (default: 5)
  -r    Replicas (default: 0)
  -e    Elasticsearch URL (default: http://localhost:9200)
  -n    How nice tar must be (default: 19)
  -u    Restart command for elastic search (default 'service elasticsearch restart')

EXAMPLES:

  ./logstash-elasticsearch-backup.sh -b "s3://bucket" \
  -i "/opt/logstash/server/data/elasticsearch/nodes/0/indices"
 
    This uses http://localhost:9200 to connect to elasticsearch and backs up
    the index from yesterday (based on system time, be careful with timezones)

  ./logstash-elasticsearch-backup.sh -b "s3://bucket" \
  -i "/opt/logstash/server/data/elasticsearch/nodes/0/indices" \
  -d "2013.07.01" -t "/mnt/es/backups" \
  -u "service elasticsearch restart" -e "http://127.0.0.1:9200" -p

    Connect to elasticsearch using 127.0.0.1 instead of localhost, backup the
    index from 2013.07.01 instead of yesterday, use boto_rsync, 
    store the archive and restore script in /mnt/es/backups (and 
    persist them) and use 'service elasticsearch restart' to restart elastic search.

EOF
}

if [ "$USER" != 'root' ] && [ "$LOGNAME" != 'root' ]; then
  echo "This script must be run as root."
  exit 1
fi

if which boto-rsync >/dev/null; then
  echo "Great, found boto-rsync"
else
  echo "This script requires boto-rsync to be installed and configured. Please install it with pip install boto_rsync"
  exit 1
fi

# Defaults
BOTOCMD="boto-rsync"
TMP_DIR="/tmp"
SHARDS=5
REPLICAS=0
ELASTICSEARCH="http://localhost:9200"
NICE=19
RESTART="service elasticsearch restart"

# Validate shard/replica values
RE_D="^[0-9]+$"

while getopts ":b:i:d:c:t:ps:r:e:n:u:h" flag
do
  case "$flag" in
    h)
      usage
      exit 0
      ;;
    b)
      S3_BASE=$OPTARG
      ;;
    i)
      INDEX_DIR=$OPTARG
      ;;
    d)
      DATE=$OPTARG
      ;;
    c)
      BOTOCMD=$OPTARG
      ;;
    t)
      TMP_DIR=$OPTARG
      ;;
    p)
      PERSIST=1
      ;;
    s)
      if [[ $OPTARG =~ $RE_D ]]; then
        SHARDS=$OPTARG
      else
        ERROR="${ERROR}Shards must be an integer.\n"
      fi
      ;;
    r)
      if [[ $OPTARG =~ $RE_D ]]; then
        REPLICAS=$OPTARG
      else
        ERROR="${ERROR}Replicas must be an integer.\n"
      fi
      ;;
    e)
      ELASTICSEARCH=$OPTARG
      ;;
    n)
      if [[ $OPTARG =~ $RE_D ]]; then
        NICE=$OPTARG
      fi
      # If nice is not an integer, just use default
      ;;
    u)
      RESTART=$OPTARG
      ;;
    ?)
      usage
      exit 1
      ;;
  esac
done

# We need an S3 base path 
if [ -z "$S3_BASE" ]; then
  ERROR="${ERROR}Please provide an s3 bucket and path with -b.\n"
fi

# We need an elasticsearch index directory
if [ -z "INDEX_DIR" ]; then
  ERROR="${ERROR}Please provide an Elasticsearch index directory with -i.\n"
fi

# If we have errors, show the errors with usage data and exit.
if [ -n "$ERROR" ]; then
  echo -e $ERROR
  usage
  exit 1
fi

# Default logstash index naming is hardcoded, as are YYYY-mm container directories.
if [ -n "$DATE" ]; then
  INDEX="logstash-$DATE"
  YEARMONTH=${DATE//\./-}
  YEARMONTH=${YEARMONTH:0:7}
else
  INDEX=`date --date='yesterday' +"logstash-%Y.%m.%d"`
  YEARMONTH=`date +"%Y-%m"`
fi
S3_TARGET="$S3_BASE/$YEARMONTH"

# Make sure there is an index
if ! [ -d $INDEX_DIR/$INDEX ]; then
  echo "The index $INDEX_DIR/$INDEX does not appear to exist."
  exit 1
fi

# Get metadata from elasticsearch
INDEX_MAPPING=`curl -s -XGET "$ELASTICSEARCH/$INDEX/_mapping"`
SETTINGS="{\"settings\":{\"number_of_shards\":$SHARDS,\"number_of_replicas\":$REPLICAS},\"mappings\":$INDEX_MAPPING}"

# Make the tmp directory if it does not already exist.
if ! [ -d $TMP_DIR ]; then
  mkdir -p $TMP_DIR
fi

# Tar and gzip the index dirextory.
cd $INDEX_DIR
nice -n $NICE tar czf $TMP_DIR/$INDEX.tgz $INDEX
cd - > /dev/null

# Create a restore script for elasticsearch
cat << EOF >> $TMP_DIR/${INDEX}-restore.sh
#!/bin/bash
# 
# ${INDEX}-restore.sh - restores elasticsearch index: $INDEX to elasticsearch
#   instance at $ELASTICSEARCH. This script expects to run in the same
#   directory as the $INDEX.tgz file.

# Make sure this index does not exist already
TEST=\`curl -XGET "$ELASTICSEARCH/$INDEX/_status" 2> /dev/null | grep error\`
if [ -z "\$TEST" ]; then
  echo "Index: $INDEX already exists on this elasticsearch node."
  exit 1
fi

curl -XPUT '$ELASTICSEARCH/$INDEX/' -d '$SETTINGS' > /dev/null 2>&1

# Extract index files
DOWNLOAD_DIR=`pwd`
cd $INDEX_DIR
if [ -f $DOWNLOAD_DIR/$INDEX.tgz ]; then
  tar xzf $DOWNLOAD_DIR/$INDEX.tgz
else
  echo "Unable to locate archive file $DOWNLOAD_DIR/$INDEX.tgz."
  exit 1
fi

# restart elasticsearch to allow it to open the new dir and file data
$RESTART
exit 0
EOF

# Put archive and restore script in s3.
# Enable server-side encryption on files copied to S3 by default
$BOTOCMD $TMP_DIR/$INDEX.tgz $S3_TARGET/$INDEX.tgz -e
$BOTOCMD $TMP_DIR/$INDEX-restore.sh $S3_TARGET/$INDEX-restore.sh -e

# cleanup tmp files
if [ -z $PERSIST ]; then
  rm $TMP_DIR/$INDEX.tgz
  rm $TMP_DIR/$INDEX-restore.sh
fi

exit 0
