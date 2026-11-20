INSERT INTO users (
  first_name,
  middle_name,
  last_name,
  username,
  pwd_hash,
  is_admin
)
-- pwd_hash values are "iterations$salt_hex$hash_hex" (salted
-- PBKDF2-HMAC-SHA256, see sqli/dao/user.py User.hash_password/check_password)
-- rather than unsalted md5(), precomputed here since plain SQL has no
-- PBKDF2 function to call. Login passwords are unchanged: superadmin/
-- superadmin, j.doe/password, s.king/password, p.parker/spidey.
VALUES
  ('Super', NULL, 'Admin', 'superadmin', '310000$e9c202553b09c3e2835dfe078f816c38$5c10e93825986c5f9ec3856ea3fcfe47afba502ec5af8bd0556ca5d10e71710c', TRUE),
  ('John', 'William', 'Doe', 'j.doe', '310000$f573fadb2af1f5249f92e312b1075ed4$4679f70cea2eb2351d5d0bd0efc1ac378969291e2c33f86c7902854cd3853a8d', FALSE),
  ('Stephen', NULL, 'King', 's.king', '310000$cd90a28edf486f3b466332949e0194ef$ff86e76d95e153b96f6528a2dd6841ef1b3418802c5dd97bfc5b90fef8dc0306', FALSE),
  ('Peter', NULL, 'Parker', 'p.parker', '310000$b5c1017a91b59f103b64c97b479bbc3b$0ceef0e033de179eaa2ffc49aea3b605b129758b7afc46fe4b9ae596241c33e5', FALSE);

INSERT INTO students (name) VALUES
  ('Chuck'), ('James'), ('Thor'), ('Clint'),
  ('Richie'), ('Bill'), ('Ben'), ('Eddie');

INSERT INTO courses (title, description) VALUES
  ('Math', '2+2 = 5'),
  ('Grammar', 'Wi learn haw tu write korektli'),
  ('Physics', 'E=mc^2');

INSERT INTO marks(student_id, course_id, points) VALUES
  (1, 1, 4), (1, 1, 5), (1, 1, 3), (1, 1, 4),
  (1, 2, 2), (1, 2, 3), (1, 3, 5), (1, 3, 5);
