import hmac
from hashlib import pbkdf2_hmac
from os import urandom
from typing import NamedTuple, Optional

from aiopg import Connection

PBKDF2_ITERATIONS = 310_000


class User(NamedTuple):
    id: int
    first_name: str
    middle_name: Optional[str]
    last_name: str
    username: str
    pwd_hash: str
    is_admin: bool

    @classmethod
    def from_raw(cls, raw: tuple):
        return cls(*raw) if raw else None

    @staticmethod
    async def get(conn: Connection, id_: int):
        async with conn.cursor() as cur:
            await cur.execute(
                'SELECT id, first_name, middle_name, last_name, '
                'username, pwd_hash, is_admin FROM users WHERE id = %s',
                (id_,),
            )
            return User.from_raw(await cur.fetchone())

    @staticmethod
    async def get_by_username(conn: Connection, username: str):
        async with conn.cursor() as cur:
            await cur.execute(
                'SELECT id, first_name, middle_name, last_name, '
                'username, pwd_hash, is_admin FROM users WHERE username = %s',
                (username,),
            )
            return User.from_raw(await cur.fetchone())

    def check_password(self, password: str):
        try:
            iterations, salt_hex, hash_hex = self.pwd_hash.split('$')
            salt = bytes.fromhex(salt_hex)
            expected = bytes.fromhex(hash_hex)
        except ValueError:
            return False
        candidate = pbkdf2_hmac('sha256', password.encode('utf-8'), salt,
                                int(iterations))
        return hmac.compare_digest(candidate, expected)

    @staticmethod
    def hash_password(password: str, iterations: int = PBKDF2_ITERATIONS) -> str:
        """Salted PBKDF2-HMAC-SHA256, stored as "iterations$salt$hash" so a
        future change in iteration count doesn't invalidate existing hashes.
        """
        salt = urandom(16)
        digest = pbkdf2_hmac('sha256', password.encode('utf-8'), salt,
                             iterations)
        return f'{iterations}${salt.hex()}${digest.hex()}'
