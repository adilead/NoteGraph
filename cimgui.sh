#!/bin/bash
git submodule update --init --recursive
cat cimgui_header_data.txt > deps/cimgui/generator/output/cimgui_impl.h
