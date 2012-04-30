#!/bin/sh
#
# run concurrent curls which download from URL to /dev/null.  output total
# and average counts to results directory.
#

# max concurrent curls to kick off
max=90
# how long to stay connected (in seconds)
duration=1
# how long to sleep between each curl, can be decimal  0.5
delay=2
# url to request from
URL=http://localhost:8015/kpcclive


#####
#mkdir -p results
echo > results
while /usr/bin/true
do
count=1
while [ $count -le $max ]
do
	curl -o /dev/null -m $duration -s -w "bytes %{size_download} avg %{speed_download} " -H "icy-metadata: 1" "$URL" >> results &
	curl -o /dev/null -m $duration -s -w "bytes %{size_download} avg %{speed_download} " -H "icy-metadata: 1" "$URL" >> results &
	curl -o /dev/null -m $duration -s -w "bytes %{size_download} avg %{speed_download} " -H "icy-metadata: 1" "$URL" >> results &
	curl -o /dev/null -m $duration -s -w "bytes %{size_download} avg %{speed_download} " -H "icy-metadata: 1" "$URL" >> results &
	curl -o /dev/null -m $duration -s -w "bytes %{size_download} avg %{speed_download} " -H "icy-metadata: 1" "$URL" >> results &
	curl -o /dev/null -m $duration -s -w "bytes %{size_download} avg %{speed_download} " -H "icy-metadata: 1" "$URL" >> results &
	curl -o /dev/null -m $duration -s -w "bytes %{size_download} avg %{speed_download} " -H "icy-metadata: 1" "$URL" >> results &
	curl -o /dev/null -m $duration -s -w "bytes %{size_download} avg %{speed_download} " -H "icy-metadata: 1" "$URL" >> results &
	curl -o /dev/null -m $duration -s -w "bytes %{size_download} avg %{speed_download} " -H "icy-metadata: 1" "$URL" >> results &
	curl -o /dev/null -m $duration -s -w "bytes %{size_download} avg %{speed_download} " -H "icy-metadata: 1" "$URL" >> results &
	curl -o /dev/null -m $duration -s -w "bytes %{size_download} avg %{speed_download} " -H "icy-metadata: 1" "$URL" >> results &
	[ "$delay" != "" ] && sleep $delay
	let count=$count+10
done
wait
done
echo done