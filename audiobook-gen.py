#!/usr/bin/env python

# Install:
#   sudo apt install pyenv
#
#   echo 'export PYENV_ROOT="$HOME/.pyenv"' >> ~/.bashrc
#   echo '[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"' >> ~/.bashrc
#   echo 'eval "$(pyenv init - bash)"' >> ~/.bashrc
#
#   echo 'export PYENV_ROOT="$HOME/.pyenv"' >> ~/.profile
#   echo '[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"' >> ~/.profile
#   echo 'eval "$(pyenv init - bash)"' >> ~/.profile

#   pyenv install 3.12
#   pyenv global 3.12
#
#   pip install --upgrade pip
#   python -m pip install torch==2.7.1 kokoro PyQt6
#
# Voices:
# - https://huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md#american-english
#

import os
import sys
import argparse
import subprocess
import glob
import wave
import warnings
import re
import importlib
import numpy as np
from typing import List, Tuple, Generator, Callable, Optional

import ebooklib
from ebooklib import epub
from bs4 import BeautifulSoup
from PyQt6.QtWidgets import (QApplication, QMainWindow, QWidget, QVBoxLayout,
                              QHBoxLayout, QGridLayout, QLabel, QPushButton,
                              QFileDialog, QComboBox, QSlider, QProgressBar,
                              QTextEdit, QListWidget, QGroupBox, QMessageBox,
                              QLineEdit, QSpinBox)
from PyQt6.QtCore import Qt, QThread, pyqtSignal
from PyQt6.QtGui import QFont, QCloseEvent


warnings.filterwarnings("ignore", message="dropout option adds dropout.")
warnings.filterwarnings("ignore", message="`torch.nn.utils.weight_norm` is deprecated in favor of")


def clean_filename(parts: List[str]) -> str:
    """Convert a list of parts into a safe filename"""
    for i in range(len(parts)):
        parts[i] = "".join(c if c.isalnum() or c in ('-', '_') else '_' for c in parts[i]).strip()
    return "_".join(parts)

def list_items(filename: str):
    """List all items in an EPUB file (for debugging)"""
    book = epub.read_epub(filename)
    for item in book.get_items_of_type(ebooklib.ITEM_DOCUMENT):
        print(item.get_id())


# Base classes and helpers for UI organization
class UIBase:
    """Base class for UI components with common functionality"""

    def create_labeled_input(self, parent_layout, label_text: str, widget, stretch=True):
        """Create a label + widget row and add to layout"""
        row_layout = QHBoxLayout()
        row_layout.addWidget(QLabel(label_text))
        row_layout.addWidget(widget)
        if stretch:
            row_layout.addStretch()
        parent_layout.addLayout(row_layout)
        return widget

    def create_file_browse_row(self, parent_layout, label_text: str, line_edit, browse_callback):
        """Create a file selection row with browse button"""
        row_layout = QHBoxLayout()
        row_layout.addWidget(QLabel(label_text))
        row_layout.addWidget(line_edit)

        browse_btn = QPushButton("Browse...")
        browse_btn.clicked.connect(browse_callback)
        row_layout.addWidget(browse_btn)

        parent_layout.addLayout(row_layout)
        return line_edit, browse_btn

    def create_spin_range_row(self, parent_layout, label_text: str, start_spin, end_spin):
        """Create a start/end spin box range selector"""
        row_layout = QHBoxLayout()
        row_layout.addWidget(QLabel(label_text))

        row_layout.addWidget(QLabel("Start:"))
        row_layout.addWidget(start_spin)

        row_layout.addWidget(QLabel("End:"))
        row_layout.addWidget(end_spin)

        row_layout.addStretch()
        parent_layout.addLayout(row_layout)
        return start_spin, end_spin

    def create_progress_section(self, parent_layout, title="Progress"):
        """Create a standard progress section with bar, status, and log"""
        group = QGroupBox(title)
        layout = QVBoxLayout(group)

        progress_bar = QProgressBar()
        layout.addWidget(progress_bar)

        status_label = QLabel("Ready")
        layout.addWidget(status_label)

        log_text = QTextEdit()
        log_text.setMaximumHeight(150)
        log_text.setReadOnly(True)
        layout.addWidget(log_text)

        parent_layout.addWidget(group)
        return progress_bar, status_label, log_text

    def create_button_row(self, parent_layout, buttons):
        """Create a horizontal button row"""
        button_layout = QHBoxLayout()
        for button in buttons:
            button_layout.addWidget(button)
        button_layout.addStretch()
        parent_layout.addLayout(button_layout)
        return button_layout

    def log_message(self, log_widget, message: str):
        """Add message to log widget and scroll to bottom"""
        log_widget.append(message)
        log_widget.ensureCursorVisible()



class LayoutHelper:
    """Helper class for creating common layout patterns"""

    @staticmethod
    def create_group_box(title: str, layout_type=None):
        """Create a group box with specified layout type"""
        group = QGroupBox(title)
        if layout_type is None:
            layout_type = QVBoxLayout
        layout = layout_type(group)
        return group, layout

    @staticmethod
    def create_grid_settings(layout, settings):
        """Create settings grid from list of (label, widget/layout) tuples"""
        for row, (label_text, item) in enumerate(settings):
            layout.addWidget(QLabel(label_text), row, 0)
            # Check if item is a layout or widget
            if isinstance(item, (QHBoxLayout, QVBoxLayout, QGridLayout)):
                layout.addLayout(item, row, 1)
            else:
                layout.addWidget(item, row, 1)

class ProgressManager:
    """Centralized progress and status management"""

    def __init__(self, progress_bar, status_label, log_widget):
        self.progress_bar = progress_bar
        self.status_label = status_label
        self.log_widget = log_widget

    def update_progress(self, progress: float, message: str):
        """Update progress bar, status, and log"""
        self.progress_bar.setValue(int(progress * 100))
        self.status_label.setText(message)
        self.log_widget.append(message)
        self.log_widget.ensureCursorVisible()

    def log(self, message: str):
        """Add message to log only"""
        self.log_widget.append(message)
        self.log_widget.ensureCursorVisible()

    def set_complete(self, message="Complete"):
        """Set progress to 100% and update status"""
        self.progress_bar.setValue(100)
        self.status_label.setText(message)

    def set_ready(self, message="Ready"):
        """Reset progress and set ready status"""
        self.progress_bar.setValue(0)
        self.status_label.setText(message)


class BookReader:
    def __init__(self, filename: str):
        self.filename = filename
        self.book = epub.read_epub(filename)
        self.title = ""
        self.parts = []

    def getTitle(self) -> str:
        """Get book title"""
        if self.title:
            return self.title
        self.title = self.book.title if self.book.title else "Unknown_Title"
        return self.title

    def setTitle(self, title):
        """Set book title"""
        self.title = title

    def getParts(self) -> List[str]:
        """Extract text parts from book"""
        if self.parts:
            return self.parts

        for item in self.book.get_items_of_type(ebooklib.ITEM_DOCUMENT):
            soup = BeautifulSoup(item.get_content(), 'html.parser')
            text = soup.get_text().strip().replace('\u00A0', ' ')
            if text:
                self.parts.append(text)

        return self.parts

    def partBasename(self, outDir, title, i):
        filename = f"{title}_part_{i:03d}"
        return os.path.join(outDir, filename)

    def makedir(self):
        title = clean_filename([self.getTitle()])
        root = os.path.dirname(os.path.abspath(self.filename))
        outDir = os.path.join(root, title)
        os.makedirs(outDir, exist_ok=True)
        return outDir, title

    def _find_parts(self, parts: List[str]) -> tuple[int, int]:
        """Find parts using interactive CLI prompt"""
        toExtract = input("Enter part range to extract or 'n' to search: ")
        try:
            # Parse as "start end" integers
            nums = [int(x) for x in toExtract.split()]
            if len(nums) == 2 and nums[0] < nums[1] and nums[0] >= 0 and nums[1] < len(parts):
                return (nums[0], nums[1])
        except (ValueError, IndexError):
            pass

        print("Finding the start of the book")
        startIdx = 0
        for i in range(0, len(parts)):
            print(f"\nIndex {i}:")
            firstWords = "\t" + parts[i][:80].replace("\n", "\n\t")
            print(firstWords)

            isStart = input("Is this the start (y/n)? ")
            if isStart == "y":
                startIdx = i
                break

        print("\nFinding the end of the book")
        endIdx = len(parts) - 1
        for i in range(endIdx, 0, -1):
            print(f"\nIndex {i}:")
            firstWords = "\t" + parts[i][:80].replace("\n", "\n\t")
            print(firstWords)

            isEnd = input("Is this the end (y/n)? ")
            if isEnd == "y":
                endIdx = i
                break

        print(f"\nBook content: {[startIdx, endIdx]}")
        return (startIdx, endIdx)

    def dump(self):
        """Dump text parts to files"""
        parts = self.getParts()
        start, end = self._find_parts(parts)
        outDir, title = self.makedir()
        if end == -1 or end >= len(parts):
            end = len(parts) - 1

        for i in range(start, end + 1):
            filepath = self.partBasename(outDir, title, i) + ".txt"
            with open(filepath, "w", encoding="utf-8") as f:
                f.write(parts[i])


class TextToAudio:
    _kokoro_module = None

    def __init__(self, voice="af_heart", speed=1.3):
        self.voice = voice
        self.speed = speed

    def default_progress_callback(self, percent: float, message: str):
        """Default progress callback that prints to console"""
        print(f"[{percent:6.1f}%] {message}")

    def _kokoro_generator(self, text: str) -> Generator:
        """Generate audio from text using Kokoro (lazy loaded)"""
        if TextToAudio._kokoro_module is None:
            TextToAudio._kokoro_module = importlib.import_module("kokoro")
        pipeline = TextToAudio._kokoro_module.KPipeline(lang_code='a', repo_id='hexgrad/Kokoro-82M')
        yield from pipeline(text, voice=self.voice, speed=self.speed, split_pattern=r"\n+")

    def _run_kokoro(self, txt, filename):
        """Run Kokoro TTS on a text file and save to WAV"""
        txt = txt.replace('\n', ' ')
        txt = txt.replace('\u00A0', ' ')
        txt = txt.replace('. . .', '.')
        
        # Remove single quotes from contractions like he'd, she'll, can't, etc.
        txt = re.sub(r"\b(\w+)'(\w+)\b", r"\1\2", txt)

        txt = txt.replace('.', '.\n')
        txt = txt.replace('!', '!\n')
        txt = txt.replace('?', '?\n')

        with wave.open(filename, "wb") as wav_file:
            wav_file.setnchannels(1)
            wav_file.setsampwidth(2)
            wav_file.setframerate(24000)

            for result in self._kokoro_generator(txt):
                if result.audio is None:
                    continue
                audio_bytes = (result.audio.numpy() * 32767).astype(np.int16).tobytes()
                wav_file.writeframes(audio_bytes)

    def run(self, text: str, filename: str, progress_callback=None):
        """Generate audio from a text file"""
        if filename.endswith('.txt'):
            filename = filename[:-4]

        if progress_callback is None:
            progress_callback = self.default_progress_callback

        waveFile = filename + ".wav"
        opusFile = filename + ".opus"

        progress_callback(5.0, "Generating WAV...")
        self._run_kokoro(text, waveFile)

        progress_callback(75.0, "Converting to OPUS...")
        cmd = ["ffmpeg", "-y", "-i", waveFile, "-af", "adelay=2s:all=true",
               "-c:a", "libopus", "-b:a", "64k", "-vbr", "on", opusFile]
        result = subprocess.run(cmd, capture_output=True, text=True)

        if result.returncode == 0:
            progress_callback(95.0, "Deleting WAV...")
            subprocess.run(["rm", waveFile])
            progress_callback(100.0, "Generation complete")


class AudioGenerationWorker(QThread):
    """Worker thread for audio generation to prevent GUI freezing"""
    progress = pyqtSignal(str, float)  # message, progress (0.0-1.0)
    finished = pyqtSignal(bool)  # success
    error = pyqtSignal(str)  # error message

    def __init__(self, voice: str, speed: float, book: BookReader, start_idx: int, end_idx: int):
        super().__init__()
        self.voice = voice
        self.speed = speed
        self.book = book
        self.start_idx = start_idx
        self.end_idx = end_idx

    def run(self):
        """Run the audio generation process in background"""
        try:
            tts = TextToAudio(self.voice, self.speed)
            outdir, title = self.book.makedir()
            total_parts = self.end_idx - self.start_idx + 1

            for i in range(self.start_idx, self.end_idx + 1):
                current_part = i - self.start_idx + 1
                basename = self.book.partBasename(outdir, title, i)

                def make_part_progress_callback(part_num, total_parts):
                    def part_progress_callback(percent: float, message: str):
                        overall_percent = ((part_num - 1) + percent / 100.0) / total_parts
                        status = f"Part {part_num}/{total_parts}: {message}"
                        self.progress.emit(status, overall_percent)
                    return part_progress_callback

                progress_callback = make_part_progress_callback(current_part, total_parts)
                tts.run(self.book.parts[i], basename, progress_callback)
                part_complete_progress = current_part / total_parts
                self.progress.emit(f"Completed part {current_part}/{total_parts}", part_complete_progress)

            self.finished.emit(True)
        except Exception as e:
            self.error.emit(str(e))

class PartSelectionWidget(QWidget, UIBase):
    """Widget for selecting book parts"""

    def __init__(self):
        super().__init__()
        self.parts = []
        self.init_ui()

    def init_ui(self):
        layout = QVBoxLayout()

        # Title
        title = QLabel("Part Selection")
        title.setFont(QFont("Arial", 12, QFont.Weight.Bold))
        layout.addWidget(title)

        # Part list
        self.part_list = QListWidget()
        self.part_list.setMaximumHeight(200)
        layout.addWidget(self.part_list)

        # Range selection
        self.start_spin = QSpinBox()
        self.start_spin.setMinimum(0)
        self.end_spin = QSpinBox()
        self.end_spin.setMinimum(0)
        self.create_spin_range_row(layout, "", self.start_spin, self.end_spin)

        # Preview section
        preview_label = QLabel("Part Preview:")
        layout.addWidget(preview_label)

        self.preview_text = QTextEdit()
        self.preview_text.setMaximumHeight(120)
        self.preview_text.setReadOnly(True)
        layout.addWidget(self.preview_text)

        self.setLayout(layout)

        # Connect signals
        self.part_list.currentRowChanged.connect(self.on_part_selected)

    def load_parts(self, parts: List[str]):
        """Load parts data and populate the list"""
        self.parts = parts
        self.part_list.clear()

        for i, part in enumerate(parts):
            preview = part[:100].replace('\n', ' ').strip()
            if len(part) > 100:
                preview += "..."

            item_text = f"Part {i}: {preview}"
            self.part_list.addItem(item_text)

        # Set up spinbox ranges
        if parts:
            self.start_spin.setMaximum(len(parts) - 1)
            self.end_spin.setMaximum(len(parts) - 1)
            self.end_spin.setValue(len(parts) - 1)

        # Select first item by default
        if self.part_list.count() > 0:
            self.part_list.setCurrentRow(0)

    def on_part_selected(self, row: int):
        """Handle part selection"""
        if row >= 0 and row < len(self.parts):
            preview = self.parts[row][:500]
            if len(self.parts[row]) > 500:
                preview += "\n\n[... content truncated ...]"
            self.preview_text.setPlainText(preview)

    def get_selected_range(self) -> tuple:
        """Get the selected part range"""
        start = self.start_spin.value()
        end = self.end_spin.value()
        if end < start:
            self.start_spin.setValue(end)
            self.end_spin.setValue(start)
        return (self.start_spin.value(), self.end_spin.value())


class AudiobookGeneratorGUI(QMainWindow, UIBase):
    """Main GUI window for audiobook generation"""

    # List of available voices (from Kokoro documentation)
    VOICES = [
        "af_heart", "af_joy", "af_laughter", "af_sarah", "af_sky", "af_wave",
        "af_bella", "af_nicole", "am_adam", "am_cooper", "am_daniel", "am_edward",
        "am_jenna", "am_katie", "am_paul"
    ]

    def __init__(self):
        super().__init__()
        self.book = None
        self.voice = "af_heart"
        self.speed = 1.3
        self.worker_thread = None
        self.progress_manager = None
        self.init_ui()

    def init_ui(self):
        """Initialize the user interface"""
        self.setWindowTitle("Audiobook Generator")
        self.setGeometry(100, 100, 900, 700)

        central_widget = QWidget()
        self.setCentralWidget(central_widget)
        main_layout = QVBoxLayout(central_widget)

        # File selection section
        file_group, file_layout = LayoutHelper.create_group_box("File Selection")
        main_layout.addWidget(file_group)

        self.epub_path = QLineEdit()
        self.epub_path.setPlaceholderText("Select an EPUB file...")
        self.create_file_browse_row(file_layout, "EPUB File:", self.epub_path, self.browse_epub_file)

        self.title_field = QLineEdit()
        self.title_field.setPlaceholderText("Book title will appear here...")
        self.create_labeled_input(file_layout, "Title:", self.title_field)

        # Voice settings section
        settings_group, settings_layout = LayoutHelper.create_group_box("Voice Settings", QGridLayout)
        main_layout.addWidget(settings_group)

        self.voice_combo = QComboBox()
        self.voice_combo.addItems(self.VOICES)
        self.voice_combo.setCurrentText(self.voice)
        LayoutHelper.create_grid_settings(settings_layout, [
            ("Voice:", self.voice_combo),
            ("Speed:", self._create_speed_control())
        ])

        # Part selection widget
        self.part_widget = PartSelectionWidget()
        self.part_widget.setVisible(False)
        main_layout.addWidget(self.part_widget)

        # Control buttons
        self.load_btn = QPushButton("Load EPUB")
        self.load_btn.setEnabled(False)
        self.generate_btn = QPushButton("Generate Audiobook")
        self.generate_btn.setEnabled(False)
        self.cancel_btn = QPushButton("Cancel")
        self.cancel_btn.setEnabled(False)

        self.create_button_row(main_layout, [self.load_btn, self.generate_btn, self.cancel_btn])

        # Progress section
        self.progress_bar, self.status_label, self.log_text = self.create_progress_section(main_layout)

        # Initialize progress manager
        self.progress_manager = ProgressManager(self.progress_bar, self.status_label, self.log_text)

        # Connect signals
        self.epub_path.textChanged.connect(self.on_epub_path_changed)
        self.voice_combo.currentTextChanged.connect(self.on_voice_changed)
        self.load_btn.clicked.connect(self.load_epub_file)
        self.generate_btn.clicked.connect(self.generate_audiobook)
        self.cancel_btn.clicked.connect(self.cancel_generation)

    def _create_speed_control(self):
        """Create speed slider control"""
        speed_layout = QHBoxLayout()
        self.speed_slider = QSlider(Qt.Orientation.Horizontal)
        self.speed_slider.setMinimum(50)  # 0.5x speed
        self.speed_slider.setMaximum(200)  # 2.0x speed
        self.speed_slider.setValue(int(100 * self.speed))
        self.speed_slider.valueChanged.connect(self.on_speed_changed)
        speed_layout.addWidget(self.speed_slider)

        self.speed_label = QLabel(f"{self.speed:.1f}x")
        self.speed_label.setMinimumWidth(40)
        speed_layout.addWidget(self.speed_label)

        return speed_layout

    def browse_epub_file(self):
        """Open file dialog to select EPUB file"""
        file_path, _ = QFileDialog.getOpenFileName(
            self, "Select EPUB File", "", "EPUB files (*.epub);;All files (*)"
        )
        if file_path:
            self.epub_path.setText(file_path)

    def on_epub_path_changed(self):
        """Handle EPUB path change"""
        path = self.epub_path.text().strip()
        has_file = bool(path and os.path.exists(path) and path.lower().endswith('.epub'))
        self.load_btn.setEnabled(has_file)

    def on_voice_changed(self, voice: str):
        """Handle voice selection change"""
        self.voice = voice
        self.progress_manager.log(f"Selected voice: {voice}")

    def on_speed_changed(self, value: int):
        """Handle speed slider change"""
        speed = value / 100.0
        self.speed = speed
        self.speed_label.setText(f"{speed:.1f}x")
        self.progress_manager.log(f"Speed set to: {speed:.1f}x")

    def load_epub_file(self):
        """Load and analyze the EPUB file"""
        epub_path = self.epub_path.text().strip()
        if not epub_path or not os.path.exists(epub_path):
            QMessageBox.warning(self, "Error", "Please select a valid EPUB file.")
            return

        try:
            self.progress_manager.log("Loading EPUB file...")
            self.load_btn.setEnabled(False)

            self.book = BookReader(epub_path)
            self.title_field.setText(self.book.getTitle())
            self.part_widget.load_parts(self.book.getParts())
            self.part_widget.setVisible(True)
            self.generate_btn.setEnabled(True)

            self.progress_manager.log(f"Loaded book: {self.book.getTitle()}")
            self.progress_manager.log(f"Found {len(self.book.getParts())} parts")
        except Exception as e:
            QMessageBox.critical(self, "Error", f"Failed to load EPUB file:\n{str(e)}")
            self.progress_manager.log(f"Error loading EPUB: {str(e)}")
        finally:
            self.load_btn.setEnabled(True)

    def generate_audiobook(self):
        """Start audiobook generation"""
        if not self.book or not self.book.getParts():
            QMessageBox.warning(self, "Error", "Please load an EPUB file first.")
            return

        title = self.title_field.text().strip()
        self.book.setTitle(title)
        start_idx, end_idx = self.part_widget.get_selected_range()

        # Confirm generation
        reply = QMessageBox.question(
            self, "Confirm Generation",
            f"Generate audiobook for:\n"
            f"Title: {title}\n"
            f"Parts {start_idx} to {end_idx}\n"
            f"Voice: {self.voice}\n"
            f"Speed: {self.speed:.1f}x\n\n"
            f"This process may take a long time.",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No
        )

        if reply != QMessageBox.StandardButton.Yes:
            return

        # Disable controls during generation
        self.generate_btn.setEnabled(False)
        self.load_btn.setEnabled(False)
        self.cancel_btn.setEnabled(True)

        # Start worker thread
        self.worker_thread = AudioGenerationWorker(self.voice, self.speed, self.book, start_idx, end_idx)
        self.worker_thread.progress.connect(self.on_progress)
        self.worker_thread.finished.connect(self.on_generation_finished)
        self.worker_thread.error.connect(self.on_generation_error)
        self.worker_thread.start()

        self.progress_manager.log("Starting audiobook generation...")

    def cancel_generation(self):
        """Cancel ongoing generation"""
        if self.worker_thread and self.worker_thread.isRunning():
            self.worker_thread.terminate()
            self.worker_thread.wait()
            self.progress_manager.log("Generation cancelled by user")
            self.on_generation_finished(False)

    def on_progress(self, message: str, progress: float):
        """Handle progress updates"""
        self.progress_manager.update_progress(progress, message)

    def on_generation_finished(self, success: bool):
        """Handle generation completion"""
        # Re-enable controls
        self.generate_btn.setEnabled(True)
        self.load_btn.setEnabled(True)
        self.cancel_btn.setEnabled(False)

        if success:
            self.progress_manager.log("Audiobook generation completed successfully!")
            self.progress_manager.set_complete("Generation complete")
            QMessageBox.information(self, "Success", "Audiobook generation completed!")
        else:
            self.progress_manager.log("Audiobook generation failed or was cancelled")
            self.progress_manager.set_ready("Generation failed")

    def on_generation_error(self, error_msg: str):
        """Handle generation errors"""
        self.progress_manager.log(f"Generation error: {error_msg}")
        QMessageBox.critical(self, "Generation Error", f"An error occurred:\n{error_msg}")
        self.on_generation_finished(False)

    def closeEvent(self, a0):
        """Handle window close event"""
        if self.worker_thread and self.worker_thread.isRunning():
            reply = QMessageBox.question(
                self, "Confirm Exit",
                "Audio generation is in progress. Are you sure you want to exit?",
                QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No
            )

            if reply == QMessageBox.StandardButton.Yes:
                self.worker_thread.terminate()
                self.worker_thread.wait()
                a0.accept()
            else:
                a0.ignore()
        else:
            a0.accept()


def process_file_cli(filename: str, args):
    """Process a file according to the specified mode

    Returns: True if successful, False on error
    """
    mode = args.mode
    if not mode:
        return False
    if mode == "dump":
        BookReader(filename).dump()
    elif mode == "dir":
        txtFiles = glob.glob(os.path.join(filename, "*.txt"))
        tts = TextToAudio(voice=args.voice, speed=args.speed)
        for f in txtFiles:
            tts.run(open(f).read(), f)
    elif mode == "txt":
        tts = TextToAudio(voice=args.voice, speed=args.speed)
        tts.run(open(filename).read(), filename)
    else:
        print(f"Unknown mode: {mode}")
        return False
    return True

def main():
    """Main entry point for audiobook generator"""
    parser = argparse.ArgumentParser(
        description="Convert ebook to audiobook",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Modes:
  gui        Launch graphical interface (default if no files specified)
  dump       Extract text from EPUB files
  dir        Generate audio from a directory of text files
  txt        Generate audio from a single text file
  (default)  Extract text and generate audio (full pipeline)

Examples:
  %(prog)s --gui                    # Launch GUI mode
  %(prog)s book.epub                # Full pipeline with interactive part selection
  %(prog)s -m dump book.epub        # Extract text only
  %(prog)s -m dir "Book Title"       # Generate audio from extracted text directory
  %(prog)s -v af_sarah -s 1.5 book.epub  # Use different voice and speed
"""
    )

    parser.add_argument("--gui", action="store_true",
                       help="Launch GUI mode")
    parser.add_argument("-m", "--mode",
                       choices=["dump", "dir", "txt", "list"],
                       help="Set the mode for processing files/dirs")
    parser.add_argument("-v", "--voice", default="af_heart",
                       help="Select the voice to use (default: af_heart)")
    parser.add_argument("-s", "--speed", type=float, default=1.3,
                       help="Set the speed of the voice (default: 1.3)")
    parser.add_argument("files", nargs="*",
                       help="Input files/dirs")

    args = parser.parse_args()

    # Launch GUI if requested or no files provided
    if args.gui or (not args.files and not args.mode):
        try:
            app = QApplication(sys.argv)
            window = AudiobookGeneratorGUI()
            window.show()
            return app.exec()
        except ImportError as e:
            print(f"GUI mode not available: {e}")
            print("Install PyQt6 with: pip install PyQt6")
            return 1
        except Exception as e:
            print(f"Failed to start GUI: {e}")
            return 1

    # Validate files exist
    for f in args.files:
        if not os.path.exists(f):
            print(f"Error: File or dir not found: {f}")
            return 1

    # Handle list mode separately
    if args.mode == "list":
        for f in args.files:
            print(f"\nListing items in: {f}")
            list_items(f)
        return 0

    # Process files
    success = True
    for f in args.files:
        print(f"\nProcessing: {f}")
        if not process_file_cli(f, args):
            success = False
            break

    return 0 if success else 1


if __name__ == '__main__':
    sys.exit(main())
