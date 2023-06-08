from setuptools import setup, find_packages

setup(
    name="corbel-client",
    version="1.0.0",
    description="Python client SDK for the Corbel high-performance search engine",
    author="Corbel Contributors",
    packages=find_packages(),
    install_requires=[
        "urllib3>=1.26.0",
    ],
    python_requires=">=3.8",
)
