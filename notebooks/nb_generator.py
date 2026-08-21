#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Universal notebook generator: reads a cell-delimited text file and outputs .ipynb.

Format in the text file:
  ##MD##      -> start markdown cell
  ##CODE##    -> start code cell
  (lines between markers are the cell source)
"""
import sys
import nbformat as nbf

def build(cells_path, out_path):
    nb = nbf.v4.new_notebook()
    nb.metadata["kernelspec"] = {
        "display_name": "Python 3",
        "language": "python",
        "name": "python3",
    }
    nb.metadata["language_info"] = {"name": "python", "version": "3.10"}

    with open(cells_path, "r", encoding="utf-8") as f:
        raw = f.read()

    cells = []
    cur_type = None
    cur_lines = []
    for line in raw.split("\n"):
        stripped = line.strip()
        if stripped == "##MD##":
            if cur_type:
                cells.append((cur_type, "\n".join(cur_lines).strip("\n")))
            cur_type = "md"
            cur_lines = []
        elif stripped == "##CODE##":
            if cur_type:
                cells.append((cur_type, "\n".join(cur_lines).strip("\n")))
            cur_type = "code"
            cur_lines = []
        else:
            cur_lines.append(line)
    if cur_type:
        cells.append((cur_type, "\n".join(cur_lines).strip("\n")))

    for ctype, source in cells:
        if not source:
            continue
        if ctype == "md":
            nb.cells.append(nbf.v4.new_markdown_cell(source))
        else:
            nb.cells.append(nbf.v4.new_code_cell(source))

    nbf.write(nb, out_path)
    print(f"Generated {out_path} with {len(nb.cells)} cells")

if __name__ == "__main__":
    build(sys.argv[1], sys.argv[2])
