#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#

#
# Copyright (c) 2017, Joyent, Inc.
#

.PHONY: all
all: toc

./node_modules/.bin/doctoc:
	npm install

.PHONY: toc
toc: | ./node_modules/.bin/doctoc
	./node_modules/.bin/doctoc --notitle --maxlevel 3 README.md
