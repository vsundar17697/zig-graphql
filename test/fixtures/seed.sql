-- Minimal Chinook-style slice: enough to exercise a scalar-only query, a
-- where/order_by/limit combination, and exactly one object relationship
-- (album -> artist), matching milestone 1's scope exactly. See docs/roadmap.md.

CREATE TABLE artist (
    artist_id serial PRIMARY KEY,
    name text NOT NULL
);

CREATE TABLE album (
    album_id serial PRIMARY KEY,
    title text NOT NULL,
    artist_id integer NOT NULL REFERENCES artist (artist_id)
);

INSERT INTO artist (name) VALUES
    ('AC/DC'),
    ('Accept');

INSERT INTO album (title, artist_id) VALUES
    ('For Those About To Rock We Salute You', 1),
    ('Let There Be Rock', 1),
    ('Balls to the Wall', 2);
