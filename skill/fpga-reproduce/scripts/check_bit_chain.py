"""Compare implementation, XSA-embedded and debug bitstreams without loading hardware."""
import argparse
import hashlib
from pathlib import Path
import zipfile


def digest(stream):
    value = hashlib.sha256()
    for block in iter(lambda: stream.read(1024 * 1024), b''):
        value.update(block)
    return value.hexdigest()


def check(bit, xsa, debug_bit=None, member=None):
    if bit.stat().st_size == 0:
        raise ValueError('Empty reference bit')
    with bit.open('rb') as stream:
        expected = digest(stream)
    hashes = {'bit': expected}
    with zipfile.ZipFile(xsa) as archive:
        entries = [p.filename for p in archive.infolist()
                   if not p.is_dir() and p.filename.lower().endswith('.bit')]
        if member is None:
            if len(entries) != 1:
                raise ValueError(f'Expected exactly one .bit in XSA; found {entries}; select --member')
            member = entries[0]
        if entries.count(member) != 1:
            raise ValueError('Selected .bit member absent or duplicated')
        with archive.open(member) as stream:
            hashes['xsa:' + member] = digest(stream)
    if debug_bit is not None:
        with debug_bit.open('rb') as stream:
            hashes['debug_bit'] = digest(stream)
    for label, value in hashes.items():
        print(f'{label}: {value}')
    if any(value != expected for value in hashes.values()):
        raise ValueError('Bitstream mismatch; rebuild/export/update the stale artifact')
    return hashes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bit', type=Path, required=True)
    parser.add_argument('--xsa', type=Path, required=True)
    parser.add_argument('--debug-bit', type=Path)
    parser.add_argument('--member')
    args = parser.parse_args()
    check(args.bit, args.xsa, args.debug_bit, args.member)
    print('PASS: supplied bitstream bytes match; freshness and board state NOT checked')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, zipfile.BadZipFile, RuntimeError) as exc:
        print(f'ERROR: {exc}')
        raise SystemExit(1)
