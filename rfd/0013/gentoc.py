
import re
from pprint import pprint
import codecs

def slugify(s):
    return re.compile('[^a-zA-Z0-9]+').sub('-', s.lower())


content = codecs.open("README.md", 'r', 'utf8').read()
toc = []
for line in content.splitlines(False):
    if line.startswith('##'):
        n, title = line.split(None, 1)
        n = len(n) - 2
        toc.append((n, title, slugify(title)))

#pprint(toc)

for n, title, slug in toc:
    print "%s- [%s](#%s)" % ('    '*n, title, slug)
