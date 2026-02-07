#!/usr/bin/env bash
#
# build.sh - Generate a static index.html for browsing an ebook library.
#
# Usage: ./build.sh /path/to/ebooks
#
# The ebook directory should contain subdirectories named after authors,
# each containing .epub files. The generated index.html is placed in the
# ebook directory root.

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 /path/to/ebooks"
    exit 1
fi

EBOOK_DIR="${1%/}"

if [ ! -d "$EBOOK_DIR" ]; then
    echo "Error: '$EBOOK_DIR' is not a directory"
    exit 1
fi

OUTPUT="$EBOOK_DIR/index.html"

# Collect author directories (first-level subdirectories only, skip hidden dirs)
authors=()
while IFS= read -r dir; do
    authors+=("$dir")
done < <(find "$EBOOK_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f\n' | sort -f)

if [ ${#authors[@]} -eq 0 ]; then
    echo "Error: No author subdirectories found in '$EBOOK_DIR'"
    exit 1
fi

# Determine which letters have authors
declare -A active_letters
for author in "${authors[@]}"; do
    letter=$(echo "${author:0:1}" | tr '[:lower:]' '[:upper:]')
    active_letters["$letter"]=1
done

# Start building HTML
cat > "$OUTPUT" << 'HTMLHEAD'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Ebook Library</title>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body {
    font-family: Georgia, "Times New Roman", serif;
    font-size: 18px;
    line-height: 1.4;
    color: #222;
    background: #fafafa;
    padding-bottom: 60px;
}
#nav {
    position: sticky;
    top: 0;
    background: #333;
    padding: 6px 8px;
    text-align: center;
    z-index: 10;
    border-bottom: 2px solid #555;
}
#nav a, #nav span {
    display: inline-block;
    min-width: 44px;
    min-height: 44px;
    line-height: 44px;
    text-align: center;
    margin: 2px 1px;
    font-size: 18px;
    font-weight: bold;
    text-decoration: none;
    border-radius: 4px;
}
#nav a {
    color: #fff;
    background: #555;
}
#nav a:hover, #nav a:focus {
    background: #0077cc;
}
#nav a.active {
    background: #0077cc;
}
#nav span.disabled {
    color: #666;
    background: none;
}
.letter-group {
    padding: 10px 16px 6px 16px;
    border-bottom: 1px solid #ddd;
}
.letter-group h2 {
    font-size: 28px;
    color: #333;
    border-bottom: 2px solid #0077cc;
    padding-bottom: 4px;
    margin-bottom: 10px;
}
.author {
    margin-bottom: 14px;
    padding-left: 8px;
}
.author h3 {
    font-size: 20px;
    color: #0055aa;
    margin-bottom: 4px;
}
.author ul {
    list-style: none;
    padding-left: 12px;
}
.author ul li {
    margin-bottom: 6px;
}
.author ul li a {
    display: inline-block;
    padding: 6px 10px;
    color: #0055aa;
    text-decoration: none;
    font-size: 16px;
    border: 1px solid #ccc;
    border-radius: 4px;
    background: #fff;
    min-height: 44px;
    line-height: 30px;
}
.author ul li a:hover, .author ul li a:focus {
    background: #e8f0fe;
    border-color: #0077cc;
}
.back-top {
    display: inline-block;
    margin: 8px 16px;
    padding: 6px 12px;
    font-size: 14px;
    color: #555;
    text-decoration: none;
}
#stats {
    text-align: center;
    padding: 12px;
    font-size: 14px;
    color: #666;
}
.hidden { display: none !important; }
</style>
</head>
<body>
<div id="nav">
HTMLHEAD

# Write the alphabet bar
# "All" button first
echo '<a href="#" onclick="showAll();return false;" id="btn-all" class="active">All</a>' >> "$OUTPUT"

for letter in {A..Z}; do
    if [ "${active_letters[$letter]+isset}" ]; then
        echo "<a href=\"#$letter\" onclick=\"filterLetter('$letter');return false;\" id=\"btn-$letter\">$letter</a>" >> "$OUTPUT"
    else
        echo "<span class=\"disabled\">$letter</span>" >> "$OUTPUT"
    fi
done

echo '</div>' >> "$OUTPUT"

# Count totals
total_authors=0
total_books=0

# Write author/book sections grouped by letter
current_letter=""
group_open=false

for author in "${authors[@]}"; do
    letter=$(echo "${author:0:1}" | tr '[:lower:]' '[:upper:]')

    # Start a new letter group if needed
    if [ "$letter" != "$current_letter" ]; then
        if $group_open; then
            echo '</div>' >> "$OUTPUT"  # close previous letter-group
        fi
        current_letter="$letter"
        group_open=true
        echo "<div id=\"$letter\" class=\"letter-group\">" >> "$OUTPUT"
        echo "<h2>$letter</h2>" >> "$OUTPUT"
    fi

    # Find epub files for this author
    epubs=()
    while IFS= read -r epub; do
        [ -n "$epub" ] && epubs+=("$epub")
    done < <(find "$EBOOK_DIR/$author" -maxdepth 1 -type f -iname '*.epub' -printf '%f\n' | sort -f)

    # Skip authors with no epubs
    if [ ${#epubs[@]} -eq 0 ]; then
        continue
    fi

    total_authors=$((total_authors + 1))

    echo '<div class="author">' >> "$OUTPUT"
    echo "<h3>$author</h3>" >> "$OUTPUT"
    echo '<ul>' >> "$OUTPUT"

    for epub in "${epubs[@]}"; do
        total_books=$((total_books + 1))
        # URL-encode the path (spaces → %20, etc.) using printf + sed
        encoded_author=$(printf '%s' "$author" | sed 's/ /%20/g; s/\[/%5B/g; s/\]/%5D/g; s/(/%28/g; s/)/%29/g')
        encoded_epub=$(printf '%s' "$epub" | sed 's/ /%20/g; s/\[/%5B/g; s/\]/%5D/g; s/(/%28/g; s/)/%29/g')
        # Display name: strip .epub extension
        display_name="${epub%.epub}"
        display_name="${display_name%.EPUB}"
        echo "<li><a href=\"$encoded_author/$encoded_epub\" download>$display_name</a></li>" >> "$OUTPUT"
    done

    echo '</ul>' >> "$OUTPUT"
    echo '</div>' >> "$OUTPUT"
done

if $group_open; then
    echo '</div>' >> "$OUTPUT"  # close last letter-group
fi

# Write stats and JS footer
cat >> "$OUTPUT" << HTMLFOOT
<div id="stats">$total_authors authors &middot; $total_books books</div>

<script>
(function() {
    var groups = document.getElementsByClassName('letter-group');
    var buttons = document.getElementById('nav').getElementsByTagName('a');
    var currentBtn = document.getElementById('btn-all');

    function setActive(btn) {
        if (currentBtn) currentBtn.className = currentBtn.className.replace(' active', '');
        btn.className += ' active';
        currentBtn = btn;
    }

    window.filterLetter = function(letter) {
        for (var i = 0; i < groups.length; i++) {
            if (groups[i].id === letter) {
                groups[i].className = 'letter-group';
            } else {
                groups[i].className = 'letter-group hidden';
            }
        }
        setActive(document.getElementById('btn-' + letter));
        window.scrollTo(0, 0);
    };

    window.showAll = function() {
        for (var i = 0; i < groups.length; i++) {
            groups[i].className = 'letter-group';
        }
        setActive(document.getElementById('btn-all'));
        window.scrollTo(0, 0);
    };
})();
</script>
</body>
</html>
HTMLFOOT

echo "Built: $OUTPUT ($total_authors authors, $total_books books)"
