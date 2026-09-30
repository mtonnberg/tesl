import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile
import unittest

from pe_audit import PE, audit_binary, inspect


def pe_image(imports=(), delayed=(), forwarders=(), dll=False):
    image = bytearray(0x2200)
    image[:2] = b'MZ'
    struct.pack_into('<I', image, 60, 0x80)
    image[0x80:0x84] = b'PE\0\0'
    struct.pack_into('<HH', image, 0x84, 0x8664, 1)
    struct.pack_into('<HH', image, 0x94, 0xf0, 0x2022 if dll else 0x22)
    optional = 0x98
    struct.pack_into('<H', image, optional, 0x20b)
    struct.pack_into('<Q', image, optional + 24, 0x140000000)
    struct.pack_into('<HH', image, optional + 40, 6, 0)
    struct.pack_into('<HH', image, optional + 48, 6, 0)
    struct.pack_into('<I', image, optional + 56, 0x3000)
    struct.pack_into('<I', image, optional + 60, 0x200)
    struct.pack_into('<HH', image, optional + 68, 3, 0x160)
    struct.pack_into('<I', image, optional + 108, 16)
    section = optional + 0xf0
    image[section:section + 8] = b'.rdata\0\0'
    struct.pack_into('<IIII', image, section + 8, 0x2000, 0x1000, 0x2000, 0x200)
    def rva(offset):
        return offset + 0xe00
    def string(offset, value):
        data = value.encode('ascii') + b'\0'
        image[offset:offset + len(data)] = data
        return rva(offset)
    for index, values, offset, stride, names, name_field in ((1, imports, 0x200, 20, 0x600, 12),
                                                            (13, delayed, 0x800, 32, 0xa00, 4)):
        if values:
            struct.pack_into('<II', image, optional + 112 + 8 * index, rva(offset), (len(values) + 1) * stride)
            for number, name in enumerate(values):
                if index == 13:
                    struct.pack_into('<I', image, offset + number * stride, 1)
                struct.pack_into('<I', image, offset + number * stride + name_field, string(names + number * 128, name))
                thunk = (0x400 if index == 1 else 0x1000) + number * 32
                hint = (0x500 if index == 1 else 0x1200) + number * 32
                struct.pack_into('<Q', image, thunk, string(hint + 2, 'function') - 2)
                if index == 1:
                    struct.pack_into('<I', image, offset + number * stride, rva(thunk))
                    struct.pack_into('<I', image, offset + number * stride + 16, rva(thunk))
                else:
                    struct.pack_into('<II', image, offset + number * stride + 12, rva(thunk), rva(thunk))
    if forwarders:
        struct.pack_into('<II', image, optional + 112, rva(0xc00), 0x400)
        struct.pack_into('<I', image, 0xc00 + 20, len(forwarders))
        struct.pack_into('<I', image, 0xc00 + 28, rva(0xc40))
        for number, name in enumerate(forwarders):
            struct.pack_into('<I', image, 0xc40 + number * 4, string(0xd00 + number * 128, name))
    return image


class PEFormatTests(unittest.TestCase):
    def test_normal_delayed_and_forwarded_imports_are_all_reported(self):
        info = PE(pe_image(['KERNEL32.dll'], ['libpq.dll'], ['USER32.MessageBoxW', 'library.dll.#42'], True)).describe()
        self.assertEqual(info['imports'], ['kernel32.dll'])
        self.assertEqual(info['delay_imports'], ['libpq.dll'])
        self.assertEqual(info['forwarded_imports'], ['user32.dll', 'library.dll'])
        self.assertEqual(info['os_version'], '6.0')
        self.assertTrue(info['is_dll'])
        self.assertTrue(info['aslr'] and info['dep'])

    def test_truncated_signatures_architecture_and_optional_headers_are_rejected(self):
        cases = [b'', b'MZ', pe_image()[:100], bytes(500)]
        for offset, shape, value in ((0x84, '<H', 0x14c), (0x98, '<H', 0x10b),
                                     (0x94, '<H', 12), (0x86, '<H', 0),
                                     (0x98 + 108, '<I', 17), (60, '<I', 0xfffffff0)):
            image = pe_image()
            struct.pack_into(shape, image, offset, value)
            cases.append(image)
        for image in cases:
            with self.subTest(size=len(image)), self.assertRaises(ValueError):
                PE(image).describe()

    def test_os_baseline_subsystem_aslr_and_dep_are_required(self):
        for offset, value in ((0x98 + 40, 11), (0x98 + 48, 11), (0x98 + 68, 1),
                              (0x98 + 70, 0x100), (0x98 + 70, 0x40)):
            image = pe_image()
            struct.pack_into('<H', image, offset, value)
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                PE(image)

    def test_import_names_cannot_be_paths_or_posix_runtimes(self):
        for name in ('../evil.dll', 'C:evil.dll', 'sub\\evil.dll', '', 'cygwin1.dll', 'msys-2.0.dll'):
            for arguments in ({'imports': [name]}, {'delayed': [name]}):
                with self.subTest(name=name, arguments=arguments), self.assertRaises(ValueError):
                    PE(pe_image(**arguments)).describe()

    def test_invalid_rvas_unterminated_tables_and_delay_virtual_addresses_fail(self):
        image = pe_image(['KERNEL32.dll'])
        struct.pack_into('<I', image, 0x200 + 12, 0xffffff00)
        with self.assertRaisesRegex(ValueError, 'RVA'):
            PE(image).describe()
        image = pe_image(['KERNEL32.dll'])
        struct.pack_into('<I', image, 0x98 + 112 + 8 + 4, 20)
        with self.assertRaisesRegex(ValueError, 'null terminator'):
            PE(image).describe()
        image = pe_image(delayed=['libpq.dll'])
        struct.pack_into('<I', image, 0x800, 0)
        with self.assertRaisesRegex(ValueError, 'RVA descriptors'):
            PE(image).describe()

    def test_managed_and_bound_images_are_rejected(self):
        for index in (11, 14):
            image = pe_image()
            struct.pack_into('<II', image, 0x98 + 112 + 8 * index, 0x1000, 20)
            with self.assertRaisesRegex(ValueError, 'bound-import and managed'):
                PE(image)

    def test_forwarded_import_requires_an_exported_symbol(self):
        for name in ('justmodule', 'module.', '../escape.symbol'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                PE(pe_image(forwarders=[name])).describe()


class PEClosureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='PE closure å ')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.program = self.bin / 'program.exe'

    def test_case_insensitive_sibling_dll_resolves_without_path(self):
        self.program.write_bytes(pe_image(imports=['KERNEL32.DLL', 'LIBPQ.DLL']))
        library = self.bin / 'libpq.dll'
        library.write_bytes(pe_image(imports=['UCRTBASE.dll'], dll=True))
        detail, dependencies = audit_binary(self.root, self.program, self.bin)
        self.assertEqual(dependencies, [library])
        self.assertEqual(audit_binary(self.root, library, self.bin)[1], [])
        self.assertFalse(detail['is_dll'])

    def test_unbundled_redist_delayed_and_forwarded_dependencies_fail(self):
        for arguments in ({'imports': ['VCRUNTIME140.dll']}, {'delayed': ['missing.dll']},
                          {'forwarders': ['missing.Func']}, {'imports': ['api-ms-win-future-l9-9-9.dll']}):
            self.program.write_bytes(pe_image(**arguments))
            with self.subTest(arguments=arguments), self.assertRaisesRegex(ValueError, 'unbundled'):
                audit_binary(self.root, self.program, self.bin)

    def test_system_shadowing_is_rejected(self):
        self.program.write_bytes(pe_image(imports=['kernel32.dll']))
        (self.bin / 'KERNEL32.DLL').write_bytes(pe_image(dll=True))
        with self.assertRaisesRegex(ValueError, 'shadows'):
            audit_binary(self.root, self.program, self.bin)

    def test_server_modules_resolve_from_owning_application_directory(self):
        modules = self.root / 'lib'
        modules.mkdir()
        module = modules / 'plpgsql.dll'
        module.write_bytes(pe_image(imports=['postgres.exe'], dll=True))
        server = self.bin / 'postgres.exe'
        server.write_bytes(pe_image())
        self.assertEqual(audit_binary(self.root, module, self.bin)[1], [server])
        with self.assertRaisesRegex(ValueError, 'unbundled'):
            audit_binary(self.root, module, modules)

    @unittest.skipIf(os.name == 'nt', 'case-sensitive fixture and symlink need Unix')
    def test_case_collisions_and_escaping_links_are_rejected(self):
        self.program.write_bytes(pe_image(imports=['private.dll']))
        first, second = self.bin / 'private.dll', self.bin / 'PRIVATE.dll'
        first.write_bytes(pe_image(dll=True))
        second.write_bytes(pe_image(dll=True))
        with self.assertRaisesRegex(ValueError, 'collision'):
            audit_binary(self.root, self.program, self.bin)
        second.unlink()
        first.unlink()
        external = self.root.parent / (self.root.name + '.dll')
        external.write_bytes(pe_image(dll=True))
        self.addCleanup(external.unlink)
        first.symlink_to(external)
        with self.assertRaisesRegex(ValueError, 'escapes'):
            audit_binary(self.root, self.program, self.bin)

    def test_nix_store_references_fail(self):
        self.program.write_bytes(pe_image() + b'/nix/store/hidden')
        with self.assertRaisesRegex(ValueError, 'Nix store'):
            inspect(self.program)

    @unittest.skipUnless(shutil.which('objdump'), 'independent PE parser unavailable')
    def test_gnu_objdump_confirms_fixture_import_names(self):
        self.program.write_bytes(pe_image(imports=['KERNEL32.dll', 'libpq.dll']))
        result = subprocess.run(['objdump', '-p', str(self.program)], check=True, capture_output=True, text=True)
        names = re.findall(r'DLL Name: (\S+)', result.stdout)
        self.assertEqual([name.casefold() for name in names], inspect(self.program)['imports'])


if __name__ == '__main__':
    unittest.main()
