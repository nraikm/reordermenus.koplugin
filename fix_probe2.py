import sys

p = sys.argv[1]
data = open(p, "rb").read()

# This file was authored exclusively with double-quoted strings; every
# single-quote byte is quote-mangling damage. Normalize them all.
data = data.replace(bytes([39]), bytes([34]))

open(p, "wb").write(data)
print("normalized", p)
