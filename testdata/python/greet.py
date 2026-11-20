"""The Python fixture lint.yml's ruff job runs on in sadbox/ci's own CI."""


def greet(name: str) -> str:
    return f"hello, {name}"


if __name__ == "__main__":
    print(greet("world"))
