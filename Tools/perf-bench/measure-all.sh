#!/usr/bin/env bash
# Runs measure-page.sh over every page in the per-page table of
# docs/database-performance.md. The server must be running (start-server.sh)
# on a database that setup.sh built.
set -euo pipefail
. "$(dirname "$0")/env.sh"
cd "$HERE"
. "$WORK/ids.env"
J=$WORK/jars
./measure-page.sh student-dashboard "$J/stu.txt" /
./measure-page.sh student-submission "$J/stu.txt" "/submissions/$SUB"
./measure-page.sh student-history "$J/stu.txt" "/testsetups/$SETUP/history"
./measure-page.sh api-submission-status "$J/stu.txt" "/api/v1/submissions/$SUB" 20
./measure-page.sh staff-submission "$J/inst.txt" "/submissions/$SUB"
./measure-page.sh instructor-submissions "$J/inst.txt" "/instructor/$ASG/submissions"
./measure-page.sh grades-csv "$J/inst.txt" /instructor/grades.csv 3
./measure-page.sh instructor-list "$J/inst.txt" /instructor
./measure-page.sh admin-dashboard "$J/admin.txt" /admin
