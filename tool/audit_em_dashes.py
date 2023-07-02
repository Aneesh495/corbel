import os
import sys

EXCLUDED_DIRS = {
    '.git',
    '.dart_tool',
    'build',
    '__pycache__',
    '.idea',
    '.vscode',
}

EXCLUDED_EXTENSIONS = {
    '.dylib',
    '.so',
    '.dll',
    '.a',
    '.o',
    '.cbl',
    '.cbl_bkd',
    '.pyc',
    '.png',
    '.jpg',
    '.jpeg',
    '.ico',
}

def audit_file(filepath: str) -> list:
    violations = []
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            for line_no, line in enumerate(f, start=1):
                # Check for unicode em-dash or en-dash
                if '\u2014' in line:
                    violations.append((line_no, 'Unicode em-dash (\\u2014)', line.strip()))
                elif '\u2013' in line:
                    violations.append((line_no, 'Unicode en-dash (\\u2013)', line.strip()))
                # Check for space-surrounded double-dash punctuation (excluding CLI flags or code operators)
                elif ' -- ' in line and not line.strip().startswith('//') and not line.strip().startswith('*') and not line.strip().startswith('#'):
                    pass
    except UnicodeDecodeError:
        # Binary file
        pass
    return violations

def main():
    root_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    total_violations = 0

    for root, dirs, files in os.walk(root_dir):
        dirs[:] = [d for d in dirs if d not in EXCLUDED_DIRS]
        for file in files:
            ext = os.path.splitext(file)[1].lower()
            if ext in EXCLUDED_EXTENSIONS:
                continue
            path = os.path.join(root, file)
            violations = audit_file(path)
            if violations:
                rel_path = os.path.relpath(path, root_dir)
                for line_no, reason, text in violations:
                    print(f'{rel_path}:{line_no}: {reason}: "{text}"')
                    total_violations += 1

    if total_violations > 0:
        print(f'\nFAIL: Found {total_violations} em-dash or en-dash violation(s).')
        sys.exit(1)
    else:
        print('SUCCESS: Verified 0 em-dash / en-dash occurrences across the entire codebase.')
        sys.exit(0)

if __name__ == '__main__':
    main()
