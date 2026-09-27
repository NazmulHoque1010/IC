import re
import sys
from pathlib import Path

# Matches the standard "TIMESTAMP host process[pid]: message" line format.
LINE_PREFIX_RE = re.compile(r'^\S+ \S+ [^:]+:\s?(.*)$')

# Used to normalize a message so lines that only differ by an ID/address are grouped as the same pattern.
HEX_RE = re.compile(r'0x[0-9a-fA-F]+')
BIGNUM_RE = re.compile(r'\d{6,}')   # session/handle IDs (long numbers)
NUM_RE = re.compile(r'\d+')         # anything else numeric (ports, counts, etc.)

def normalize(message: str) -> str:
    """Turn a message into a generic 'signature' by replacing hex and
    numeric values with placeholders."""
    sig = HEX_RE.sub('<HEX>', message)
    sig = BIGNUM_RE.sub('<BIGNUM>', sig)
    sig = NUM_RE.sub('<NUM>', sig)
    return sig.strip()

def main():
    default_path = r"C:\Users\Lenovo\Desktop\IC\Python training\Janus log\janus-last-month.log"
    
    if len(sys.argv) == 2:
        log_path = Path(sys.argv[1])
    else:
        log_path = Path(default_path)
        print(f"Using default log path: {log_path}\n")

    if not log_path.exists():
        print(f"File not found: {log_path}")
        sys.exit(1)

    patterns = {}
    no_prefix_match = {}
    total_lines = 0

    with open(log_path, 'r', encoding='utf-8', errors='replace') as f:
        for raw_line in f:
            total_lines += 1
            line = raw_line.rstrip('\n')

            match = LINE_PREFIX_RE.match(line)
            if not match:
                sig = normalize(line)
                if sig not in no_prefix_match:
                    no_prefix_match[sig] = {"count": 0, "example": line}
                no_prefix_match[sig]["count"] += 1
                continue

            message = match.group(1)
            sig = normalize(message)

            if sig not in patterns:
                patterns[sig] = {"count": 0, "example": line}
            patterns[sig]["count"] += 1

    sorted_patterns = sorted(patterns.items(), key=lambda kv: -kv[1]["count"])
    sorted_no_prefix = sorted(no_prefix_match.items(), key=lambda kv: -kv[1]["count"])

    # --- Write unique lines ONLY to the output log file ---
    output_log_path = log_path.parent / "unique_occurrences.log"
    with open(output_log_path, 'w', encoding='utf-8') as out_f:
        for sig, info in sorted_patterns:
            out_f.write(info['example'] + '\n')
            
        for sig, info in sorted_no_prefix:
            out_f.write(info['example'] + '\n')

    # --- Print summary to terminal ---
    total_unique = len(sorted_patterns) + len(sorted_no_prefix)
    
    print(f"Scanned {total_lines:,} total lines.")
    print(f"Wrote unique lines to: {output_log_path}")
    print(f"\nTotal unique occurrences: {total_unique}")

if __name__ == "__main__":
    main()