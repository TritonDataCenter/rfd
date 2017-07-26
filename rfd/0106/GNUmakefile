PANDOC ?= pandoc
RST2PDF ?= rst2pdf
RST2HTML5 ?= rst2html5
TITLE ?= How to Go at Joyent

.SUFFIXES: .html .md .pdf .rst

default:: README

README:: README.pdf README.html README.md

README.md: README.rst header.md
	$(PANDOC) -o $@ -f rst -t markdown $<
	cat header.md README.md > README.md.new
	mv README.md.new README.md

%.html: %.rst
	$(RST2HTML5) \
		--title="$(TITLE)" \
		--date \
		--time \
		--toc-top-backlinks \
		--strict \
		--smart-quotes=yes \
		--rfc-references \
		--trim-footnote-reference-space \
		--bootstrap-css \
		--embed-content \
		--section-subtitles \
		--pretty-print-code \
		$< $@

%.md: %.rst
	$(PANDOC) -o $@ -f rst -t markdown $<

%.pdf: %.rst
	$(RST2PDF) \
		--real-footnotes \
		-o $@ $<

init-env::
	virtualenv .
	sh -c '. bin/activate && pip install pygments rst2pdf rstcheck rst2html5 rst2html5-tools'

clean::
	rm -rf .Python bin/ include/ lib/ pip-selfcheck.json README.pdf README.html
