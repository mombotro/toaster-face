#!/bin/sh
# Build toaster-face: header -> Faces.swift -> binary.
set -e
cd "$(dirname "$0")"
python3 gen_faces.py toaster_faces.h Faces.swift
swiftc -O main.swift Faces.swift -o toaster-face
echo "built ./toaster-face"
