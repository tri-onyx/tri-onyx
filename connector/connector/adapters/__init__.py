"""Chat platform adapters."""

from connector.adapters.base import BaseAdapter
from connector.adapters.matrix import MatrixAdapter

__all__ = ["BaseAdapter", "MatrixAdapter"]
