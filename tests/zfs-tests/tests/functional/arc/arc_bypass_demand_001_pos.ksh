#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
#
# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
#
# A full copy of the text of the CDDL should have accompanied this
# source.  A copy of the CDDL is also available via the Internet at
# https://opensource.org/license/CDDL-1.0.
#

#
# Copyright 2026, tiehexue <tiehexue@hotmail.com>. All rights reserved.
#

. $STF_SUITE/include/libtest.shlib

#
# DESCRIPTION:
# I/O that bypasses the ARC (Direct I/O, or datasets with caching disabled
# such as primarycache=metadata) never allocates ARC buffers, so it cannot
# trigger the normal arc_adapt() growth path.  Verify that such I/O is
# accounted for by the arcstats:bypass_demand counter, which feeds
# arc_bypass_adapt() so that budgets derived from the target cache size
# (e.g. the dbuf cache) reflect the I/O actually being served.
#
# STRATEGY:
# 1. Create a dataset with primarycache=metadata, so data is never cached
#    and every data block read must bypass the ARC.
# 2. Write a file and sync.  The buffered (partial-block) write leaves the
#    data dbufs resident in the dbuf cache holding their data, so read the
#    file a couple of times first: each read releases the dbufs, and since
#    they are not cacheable they are then destroyed, guaranteeing the reads
#    below are genuine cache misses.
# 3. Take a baseline of arcstats:bypass_demand.
# 4. Read the file back - each data block is a cache miss served by
#    bypassing the ARC.
# 5. Verify arcstats:bypass_demand increased by at least the file size.
# 6. Read the file again and verify the counter keeps growing, proving the
#    data is not being retained (each read is a fresh cache miss).
#

verify_runnable "both"

BYPS_DATASET=$TESTPOOL/bypass
BYPS_MNTPT=$TESTDIR/bypass_mnt
BYPS_FILE=$BYPS_MNTPT/bypass.data

# 1 MiB, a multiple of the default 128 KiB recordsize.
FILESIZE=$((1024 * 1024))
BS=1024
COUNT=$((FILESIZE / BS))

function cleanup
{
	if datasetexists $BYPS_DATASET; then
		log_must zfs destroy -r $BYPS_DATASET
	fi
}

log_onexit cleanup

log_assert "bypassing the ARC is counted by arcstats:bypass_demand"

log_must zfs create -o primarycache=metadata \
    -o mountpoint=$BYPS_MNTPT $BYPS_DATASET
log_must zfs set recordsize=128k $BYPS_DATASET
log_must dd if=/dev/urandom of=$BYPS_FILE bs=$BS count=$COUNT
log_must sync

#
# The buffered write above left the data dbufs resident in the dbuf cache
# holding their data (partial-block writes mark the dbufs as partially read,
# which keeps them cached even though the dataset is not ARC-cacheable).
# Reading a non-cacheable dbuf clears that flag and destroys the dbuf on
# release, so read the file a couple of times to flush them.  Only then are
# the reads below guaranteed to miss the cache and hit the bypass path.
#
log_must cat $BYPS_FILE >/dev/null
log_must cat $BYPS_FILE >/dev/null

typeset -i before
typeset -i after
typeset -i delta

before=$(kstat arcstats.bypass_demand)

log_must cat $BYPS_FILE >/dev/null

after=$(kstat arcstats.bypass_demand)
((delta = after - before))
log_note "first read: bypass_demand $before -> $after (+$delta)"
log_must test $delta -ge $FILESIZE

before=$after
log_must cat $BYPS_FILE >/dev/null

after=$(kstat arcstats.bypass_demand)
((delta = after - before))
log_note "second read: bypass_demand $before -> $after (+$delta)"
log_must test $delta -ge $FILESIZE

log_pass "bypassing the ARC is counted by arcstats:bypass_demand"
