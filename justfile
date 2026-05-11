# neomouse — developer commands.
# Install just with `cargo install just` (or `brew install just`).
# Run `just` (or `just --list`) for the full list. `just all` is the catch-all.

# Swift Testing (`import Testing`) needs Testing.framework + lib_TestingInterop
# resolved at runtime. Under Command Line Tools they live at these paths;
# under full Xcode the toolchain finds them itself and the flags are no-ops.
dev_dir := `xcode-select -p`

# Default: print available recipes.
default:
    @{{just_executable()}} --list

# Build the debug binary → .build/debug/neomouse
build:
    swift build

# Build the release binary → .build/release/neomouse
release:
    swift build -c release

# Build and run the debug binary
run:
    swift run

# Build and run the release binary
run-release:
    swift run -c release

# Run the test suite
test:
    swift test \
        -Xswiftc -F -Xswiftc {{dev_dir}}/Library/Developer/Frameworks \
        -Xlinker -rpath -Xlinker {{dev_dir}}/Library/Developer/Frameworks \
        -Xlinker -rpath -Xlinker {{dev_dir}}/Library/Developer/usr/lib

# Check Swift formatting / style
lint:
    swift format lint --strict --recursive Sources Tests

# Auto-format Swift sources in place
fmt:
    swift format -i --recursive Sources Tests

# Lint + test — what the pre-commit hook runs
check: lint test

# Catch-all: lint + test + release build — what CI runs
all: lint test release

# Remove SwiftPM build artifacts
clean:
    swift package clean
    rm -rf .build
