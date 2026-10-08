#!/bin/bash
# Dağıtım paketi: bash paketle.sh  ->  Asistan.zip
set -e
cd "$(dirname "$0")"
bash build.sh
rm -f Asistan.zip
ditto -c -k --keepParent Asistan.app Asistan.zip
echo "Hazır: $(pwd)/Asistan.zip"
