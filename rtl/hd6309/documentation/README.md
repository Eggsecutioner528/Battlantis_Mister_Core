# hd6309i.v provenance

`../hd6309i.v` is Roger Taylor's Hitachi HD6309 native-mode extension of
Greg Miller's cycle-accurate MC6809 core, vendored in from
[Nitrobotics/hd6309](https://github.com/Nitrobotics/hd6309) (`hd6309i.v`,
commit as of 2026-08-28).

Per that repository's own README: work started by Roger Taylor in May 2017,
published to GitHub on Jan 15, 2025. It shares Greg Miller's original core's
register naming and E/Q bus protocol closely enough that it drops into this
project's existing `mc6809i` wiring in `Battlantis.sv` with no adapter
module needed, unlike Jotego's `jtkcpu` (`rtl/jtkcpu/`), which was tried
first for this same purpose and found to emulate a different, Konami-
proprietary CPU (052001/052526) rather than a genuine HD6309 -- see
`project_history/TASKS.md`'s Rack 'Em Up section for that investigation.

Roger Taylor is directly credited in Greg Miller's own
`rtl/mc6809/documentation/Acknowledgements.md` as a close collaborator on
the original mc6809 core (debugging `CWAI`/`SYNC`/`/HALT` issues), so this
fork carries the same lineage and care as the base core this project
already uses for real-hardware Battlantis builds.

Licensing: `hd6309i.v` itself carries no separate license statement beyond
Greg Miller's own original header comments, which it retains and extends.
Treated here under the same BSD terms Greg Miller offers for the base
`mc6809i.v` core (see `LICENSE.md` in this directory, copied from
`rtl/mc6809/documentation/LICENSE.md`) -- both authors should be credited
together in any distribution of this project.
