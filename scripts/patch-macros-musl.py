#!/usr/bin/env python3
"""Patch PyTorch c10/macros/Macros.h for musl libc compatibility.

On musl (OHOS), <assert.h> declares __assert_fail as a C function without
'noexcept'. PyTorch's Macros.h redeclares it WITH 'noexcept', causing
"exception specification in declaration does not match previous declaration".

Fix: wrap the redeclaration with #if !defined(__MUSL__) so it's skipped on musl.
"""
import re
import sys

MACROS_H = sys.argv[1] if len(sys.argv) > 1 else 'c10/macros/Macros.h'

try:
    with open(MACROS_H, 'r') as f:
        content = f.read()
except FileNotFoundError:
    print(f"Macros.h not found at {MACROS_H}, skipping patch")
    sys.exit(0)

# Pattern: the exact 5-line __assert_fail forward declaration in Macros.h
pattern = (
    r'    void\n'
    r'    __assert_fail\(\n'
    r'        const char\* assertion,\n'
    r'        const char\* file,\n'
    r'        unsigned int line,\n'
    r'        const char\* function\) noexcept __attribute__\(\(__noreturn__\)\);'
)

if re.search(pattern, content):
    guard = '#if !defined(__MUSL__)\n' + pattern + '\n#endif  // !__MUSL__'
    new_content = re.sub(pattern, guard, content)
    with open(MACROS_H, 'w') as f:
        f.write(new_content)
    print('Patched Macros.h: wrapped __assert_fail with !__MUSL__ guard')
else:
    # The pattern might already be patched or have different formatting
    if '#if !defined(__MUSL__)' in content:
        print('Macros.h already patched')
    else:
        print('Macros.h __assert_fail pattern not found (may be different version)')
