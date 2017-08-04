ASCIIDOCTOR ?= asciidoctor
ASCIIDOCTOR_PDF ?= asciidoctor-pdf
DATE ?= "`date +%Y-%m-%d`"

.SUFFIXES: .adoc .html .9 .pdf

default:: check README

README:: README.pdf README.html

%.html: %.adoc front-matter.adoc
	$(ASCIIDOCTOR) \
		-r asciidoctor-bibtex \
		--attribute=skip-front-matter \
		--attribute=revdate="$(DATE)" \
		-b html5 \
		-o $@ -n $<

%.pdf: %.adoc front-matter.adoc
	$(ASCIIDOCTOR_PDF) -b pdf -o $@ -n $<

%.9: %.adoc
	$(ASCIIDOCTOR) -b manpage -o $@ -n $<

check::
	$(MAKE) -C examples check

init-env::
	# sudo port install ruby2.4
	# sudo gem2.4 install asciidoctor-pdf asciidoctor-diagram asciidoctor-bibtex
	# sudo gem2.4 install asciidoctor-latex --pre

clean::
	rm -rf README.pdf README.html README.9
