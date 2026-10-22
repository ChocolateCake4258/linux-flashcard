CREATE TABLE IF NOT EXISTS lesson (id INTEGER PRIMARY KEY, message TEXT NOT NULL);
INSERT INTO lesson (id, message) VALUES (1, 'Привет, LinuxFlashcard!');
SELECT message FROM lesson WHERE id = 1;
