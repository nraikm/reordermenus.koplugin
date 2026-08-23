import sys

p = sys.argv[1]
data = open(p, "rb").read()

# Fix pattern:  "tools' }  ->  "tools" }   (mangled closing quote)
old = bytes([34, 116, 111, 111, 108, 115, 39, 32, 125])
new = bytes([34, 116, 111, 111, 108, 115, 34, 32, 125])
data = data.replace(old, new)

open(p, "wb").write(data)
print("fixed", p)
