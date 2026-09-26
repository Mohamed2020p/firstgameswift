# -*- coding: utf-8 -*-
"""Runs the complete audio synthesis: engines + sfx + ui + ambience + music.  python tools/make_audio_all.py [--kind sfx|ambience|music|engine|extra] [--only a,b]"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_audio as M          # noqa: E402
import audio_sfx                # noqa: E402,F401
import audio_music              # noqa: E402,F401

if __name__ == "__main__":
    M.main()
