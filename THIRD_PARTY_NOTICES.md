# Third-party reference notices

## Mac Sai

- Project: Mac Sai
- Repository: https://github.com/iliyami/MacSai
- License: BSD 3-Clause
- Copyright: Copyright (c) 2026, Mac Sai Contributors
- License copy: `ThirdParty/MacSai-LICENSE.txt`

Mac Sai's public source code and tests were reviewed while designing the cleanup-policy changes in this integration package. MacStorageLens keeps its own cleanup architecture and independently implements the resulting behavior/policy rules rather than importing Mac Sai source files into the build.

The attribution and license copy are retained conservatively so the provenance of the reviewed open-source work remains explicit if this package is redistributed.

## Mole

- Project: Mole, https://github.com/tw93/Mole
- Upstream license: GNU GPL v3.0

Mole's public documentation and locally installed behavior were researched for
protection lists, busy-application exclusions and incomplete-scan handling.
MacStorageLens independently implements these ideas. It does not copy, link,
embed or execute Mole scripts or executables. If present, the user's local
`~/.config/mole/whitelist` is read as configuration data, without shell evaluation.
Mole remains a separate optional installation; MacStorageLens has no dependency
on its binaries. Its GPL license does not replace this project's MIT license.
