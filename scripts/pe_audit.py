"""Inspect native Windows PE imports without executing binaries or using PATH.

Only declared Windows 11 system libraries and files beside the owning executable
satisfy imports. Delayed imports and exported forwarders join the same closure.
Native installed tests remain necessary for dynamic LoadLibrary calls and APIs.
"""

from pathlib import Path
import re
import struct


SYSTEM_DLLS = frozenset(name.casefold() for name in (
    'ADVAPI32.dll', 'BCRYPT.dll', 'CRYPT32.dll', 'CRYPTBASE.dll', 'CRYPTSP.dll',
    'DNSAPI.dll', 'GDI32.dll', 'IMM32.dll', 'IPHLPAPI.dll', 'KERNEL32.dll',
    'KERNELBASE.dll', 'MSVCRT.dll', 'NTDLL.dll', 'OLE32.dll', 'OLEAUT32.dll',
    'POWRPROF.dll', 'PROFAPI.dll', 'PSAPI.dll', 'RPCRT4.dll', 'SECUR32.dll',
    'SETUPAPI.dll', 'SHELL32.dll', 'SHLWAPI.dll', 'USER32.dll', 'USERENV.dll',
    'UCRTBASE.dll', 'VERSION.dll', 'WINHTTP.dll', 'WININET.dll', 'WINMM.dll',
    'WINTRUST.dll', 'WS2_32.dll', 'WTSAPI32.dll', 'NORMALIZ.dll', 'NETAPI32.dll',
    'COMCTL32.dll', 'COMDLG32.dll', 'DBGHELP.dll', 'SHCORE.dll', 'WLDAP32.dll',
    'api-ms-win-crt-conio-l1-1-0.dll', 'api-ms-win-crt-convert-l1-1-0.dll',
    'api-ms-win-crt-environment-l1-1-0.dll', 'api-ms-win-crt-filesystem-l1-1-0.dll',
    'api-ms-win-crt-heap-l1-1-0.dll', 'api-ms-win-crt-locale-l1-1-0.dll',
    'api-ms-win-crt-math-l1-1-0.dll', 'api-ms-win-crt-multibyte-l1-1-0.dll',
    'api-ms-win-crt-process-l1-1-0.dll',
    'api-ms-win-crt-runtime-l1-1-0.dll', 'api-ms-win-crt-stdio-l1-1-0.dll',
    'api-ms-win-crt-string-l1-1-0.dll', 'api-ms-win-crt-time-l1-1-0.dll',
    'api-ms-win-crt-utility-l1-1-0.dll',
    # OCaml's WaitOnAddress/WakeByAddressAll use Synchronization.lib. Microsoft
    # documents this exact API set as supported from Windows 8 onward:
    # https://learn.microsoft.com/windows/win32/api/synchapi/nf-synchapi-waitonaddress
    'api-ms-win-core-synch-l1-2-0.dll',
))


def library_name(value):
    if not re.fullmatch(r'[A-Za-z0-9_+.-]+\.(?:dll|exe)', value, re.IGNORECASE) or '..' in value:
        raise ValueError(f'invalid Windows import name: {value!r}')
    if value.casefold().startswith(('cyg', 'msys-')):
        raise ValueError(f'POSIX compatibility runtime is forbidden: {value}')
    return value.casefold()


class PE:
    def __init__(self, data):
        self.data = data
        if len(data) < 64 or data[:2] != b'MZ':
            raise ValueError('expected a native Windows PE image')
        pe = self.number('<I', 60)
        if self.read(pe, 4) != b'PE\0\0':
            raise ValueError('missing PE signature')
        machine, sections = self.number('<HH', pe + 4)
        optional_size, self.characteristics = self.number('<HH', pe + 20)
        if machine != 0x8664 or not 1 <= sections <= 96 or not self.characteristics & 2:
            raise ValueError('PE image is not an executable AMD64 image')
        optional = pe + 24
        self.read(optional, optional_size)
        if optional_size < 112 or self.number('<H', optional) != 0x20b:
            raise ValueError('expected a PE32+ optional header')
        self.image_base = self.number('<Q', optional + 24)
        self.os_version = self.number('<HH', optional + 40)
        self.subsystem_version = self.number('<HH', optional + 48)
        self.headers_size = self.number('<I', optional + 60)
        self.subsystem, flags = self.number('<HH', optional + 68)
        if self.subsystem not in (2, 3):
            raise ValueError('PE image must use the Windows GUI or console subsystem')
        if flags & 0x140 != 0x140:
            raise ValueError('PE image must enable ASLR and DEP')
        if any(version > (10, 0) or version == (0, 0) for version in (self.os_version, self.subsystem_version)):
            raise ValueError('PE header requires an OS newer than Windows 11 or omits its OS version')
        count = self.number('<I', optional + 108)
        if count > 16 or optional_size < 112 + 8 * count:
            raise ValueError('invalid PE data-directory table')
        self.directories = [self.number('<II', optional + 112 + 8 * i) for i in range(count)]
        self.sections = []
        for index in range(sections):
            offset = optional + optional_size + index * 40
            self.read(offset, 40)
            virtual_size, rva, raw_size, raw = self.number('<IIII', offset + 8)
            self.read(raw, raw_size)
            self.sections.append((rva, virtual_size, raw, raw_size))
        if self.directory(11) != (0, 0) or self.directory(14) != (0, 0):
            raise ValueError('bound-import and managed PE images are not accepted')

    def read(self, offset, size):
        if offset < 0 or size < 0 or offset + size > len(self.data):
            raise ValueError('truncated PE structure')
        return self.data[offset:offset + size]

    def number(self, shape, offset):
        values = struct.unpack(shape, self.read(offset, struct.calcsize(shape)))
        return values[0] if len(values) == 1 else values

    def directory(self, index):
        return self.directories[index] if index < len(self.directories) else (0, 0)

    def offset(self, rva, size=1):
        if 0 < rva < self.headers_size and rva + size <= self.headers_size:
            self.read(rva, size)
            return rva
        matches = [raw + rva - start for start, virtual_size, raw, raw_size in self.sections
                   if start <= rva and rva + size <= start + raw_size]
        if len(matches) != 1:
            raise ValueError('PE RVA has no unique file-backed section')
        self.read(matches[0], size)
        return matches[0]

    def string(self, rva):
        result = bytearray()
        for i in range(1024):
            byte = self.data[self.offset(rva + i)]
            if byte == 0:
                try:
                    return result.decode('ascii')
                except UnicodeDecodeError as error:
                    raise ValueError('non-ASCII PE import string') from error
            result.append(byte)
        raise ValueError('unterminated PE import string')

    def imports(self, index, stride, name_offset, delay=False):
        rva, size = self.directory(index)
        if not rva and not size:
            return []
        if not rva or not stride <= size <= 1024 * 1024:
            raise ValueError('invalid PE import directory')
        needed = []
        for entry in range(0, size - stride + 1, stride):
            offset = self.offset(rva + entry, stride)
            if not any(self.read(offset, stride)):
                return needed
            name = self.number('<I', offset + name_offset)
            if delay:
                attributes = self.number('<I', offset)
                if attributes != 1:
                    raise ValueError('delay imports must use RVA descriptors')
            lookup = self.number('<I', offset + (16 if delay else 0))
            address = self.number('<I', offset + (12 if delay else 16))
            if not address:
                raise ValueError('PE import lacks its address table')
            self.thunks(lookup or address)
            needed.append(library_name(self.string(name)))
        raise ValueError('PE import directory lacks its null terminator')

    def thunks(self, rva):
        for index in range(128 * 1024):
            value = self.number('<Q', self.offset(rva + index * 8, 8))
            if value == 0:
                return
            if value & (1 << 63):
                if value & 0x7fffffffffff0000:
                    raise ValueError('invalid PE ordinal import')
            elif value > 0xffffffff or not self.string(value + 2):
                raise ValueError('invalid PE named import')
        raise ValueError('unterminated PE import thunk table')

    def forwarders(self):
        rva, size = self.directory(0)
        if not rva and not size:
            return []
        if not rva or size < 40:
            raise ValueError('invalid PE export directory')
        offset = self.offset(rva, 40)
        count, table = self.number('<I', offset + 20), self.number('<I', offset + 28)
        if count > 1024 * 1024:
            raise ValueError('oversized PE export table')
        needed = []
        for index in range(count):
            function = self.number('<I', self.offset(table + 4 * index, 4))
            if rva <= function < rva + size:
                forward = self.string(function)
                module, separator, symbol = forward.rpartition('.')
                if not separator or not symbol:
                    raise ValueError('malformed PE exported forwarder')
                if not module.casefold().endswith(('.dll', '.exe')):
                    module += '.dll'
                needed.append(library_name(module))
        return needed

    def describe(self):
        return {'imports': self.imports(1, 20, 12), 'delay_imports': self.imports(13, 32, 4, True),
                'forwarded_imports': self.forwarders(), 'os_version': '.'.join(map(str, self.os_version)),
                'subsystem_version': '.'.join(map(str, self.subsystem_version)),
                'is_dll': bool(self.characteristics & 0x2000), 'aslr': True, 'dep': True}


def inspect(path):
    data = Path(path).read_bytes()
    if b'/nix/store/' in data:
        raise ValueError(f'PE image contains a Nix store reference: {path}')
    try:
        return PE(data).describe()
    except ValueError as error:
        raise ValueError(f'{path}: {error}') from error


def audit_binary(root, path, application_directory):
    root, path, application_directory = Path(root).resolve(), Path(path), Path(application_directory)
    for candidate in (path, application_directory):
        if not candidate.resolve().is_relative_to(root):
            raise ValueError(f'Windows runtime path escapes payload: {candidate}')
    siblings = {}
    for sibling in application_directory.iterdir():
        if sibling.is_file():
            key = sibling.name.casefold()
            if key in siblings:
                raise ValueError(f'case-insensitive Windows runtime collision: {sibling.name}')
            siblings[key] = sibling
    detail, dependencies = inspect(path), []
    for name in sorted(set(detail['imports'] + detail['delay_imports'] + detail['forwarded_imports'])):
        if name in SYSTEM_DLLS:
            if name in siblings:
                raise ValueError(f'payload shadows a Windows system library: {name}')
            continue
        if name not in siblings:
            raise ValueError(f'unbundled Windows dependency in {path}: {name}')
        dependency = siblings[name]
        if dependency.is_symlink() or not dependency.resolve().is_relative_to(root):
            raise ValueError(f'Windows dependency escapes payload: {dependency}')
        dependencies.append(dependency)
    return detail, dependencies
