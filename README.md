# Scripts Collection

This repository contains various utility scripts for media processing, web scraping, and automation tasks.

## Scripts Overview

### goodreads.py
Python script that scrapes Goodreads book lists or shelves and generates an HTML page with a sortable table of books including ratings, covers, and links.

**Dependencies:** `bs4`, `urllib`, `getopt` (standard library), `lxml`

**Usage:**
```bash
./goodreads.py -a <minAvg> -c <minCount> <type:name:count>...
```
- `-a`: Minimum average rating (default: 3.8)
- `-c`: Minimum rating count (default: 500)
- `<type:name:count>`: Goodreads list/shelf parameters

**Requirements:** Requires `goodreads.cookie` file with valid session cookie for authentication.

### rename.py
Simple Python script that renames .mkv files in the current directory based on names listed in a file called 'list'.

**Usage:**
```bash
./rename.py
```
Requires a 'list' file with one name per line.

### netrender.sh
Shell script for managing Blender network rendering.

**Usage:**
```bash
./netrender.sh start  # Starts master and slave rendering processes
./netrender.sh stop   # Kills all blender processes
```

### mkv-convert.py
Python script that finds all video files (.avi, .mp4, .mov, .mpg, .mpeg, .divx, .m4v) in the current directory and converts them to .mkv format using mkvmerge.

**Usage:**
```bash
./mkv-convert.py
```
Original files are deleted after conversion.

### mkv-clean.sh
Shell script that validates .mkv files and fixes common issues.

**Usage:**
```bash
./mkv-clean.sh <directory>
```
- Validates files using mkvalidator
- Zeros corrupted files
- Remuxes files with issues using mkclean

### img2vid.sh
Shell script that converts a sequence of numbered PNG images to a high-quality video.

**Usage:**
```bash
./img2vid.sh <bitrate> <output_file>
```
Uses ffmpeg 2-pass encoding with libx264 codec at 24fps.

### encd.sh
Shell script for encoding video files to .mkv using ffmpeg.

**Usage:**
```bash
./encd.sh <input_file> <output_file>
```
Uses libx264 codec with ultrafast preset.

### clean.sh
Shell script that sets proper ownership and permissions on files in a directory.

**Usage:**
```bash
./clean.sh <directory>
```
Sets ownership to root:root and applies specific read/write/execute permissions.

### audiobook-gen.py
Comprehensive Python script for generating audiobooks from EPUB files using text-to-speech.

**Features:**
- GUI mode with PyQt6 interface
- CLI mode with multiple processing options
- Extracts text from EPUB files
- Uses Kokoro TTS engine
- Supports multiple voices and speed settings
- Generates OPUS audio files

**Dependencies:** `ebooklib`, `bs4`, `PyQt6`, `torch`, `kokoro`, `numpy`, `wave`, `argparse` (and others)

**Usage:**
```bash
# GUI mode
./audiobook-gen.py --gui

# Extract text only
./audiobook-gen.py -m dump book.epub

# Generate audio from directory of text files
./audiobook-gen.py -m dir "Book Directory"

# Full pipeline
./audiobook-gen.py book.epub
```

### fix-subtitles.py
Interactive Python script for fixing subtitle tracks in .mkv files.

**Features:**
- Analyzes .mkv files and displays track information
- Allows marking/unmarking default subtitle tracks
- Sets forced display flags
- Interactive commands for batch processing

**Dependencies:** `mkvtoolnix` (mkvinfo, mkvpropedit, mkvmerge)

**Usage:**
```bash
./fix-subtitles.py [paths...]
```
Run interactively on .mkv files to set subtitle track properties.

## Installation Notes

Many scripts require external tools:
- **FFmpeg**: For video processing scripts
- **MKVToolNix**: For mkv manipulation
- **Python packages**: Install via pip for Python scripts
- **Pyenv**: Recommended for audiobook-gen.py Python environment setup

## Security Note

Some scripts handle file permissions or execute system commands. Use with caution and review code before running on important files.
