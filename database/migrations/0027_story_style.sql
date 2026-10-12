-- Story text style: how the client draws a story's words (clean, loud, soft, glow, stamp, type).
--
-- Stories that exist keep the plain look: they get 'clean', which is also what an app that sends no
-- style gets. The allowed names live in the API (domain.StoryTextStyleNames), as the story backgrounds
-- do; the database only checks the shape of the name, so a new style is a code change and never another
-- migration (a CHECK listing the names would have to be dropped and recreated each time). Adding the
-- column with a constant default is a catalogue-only change, and applying this again changes nothing.
ALTER TABLE stories ADD COLUMN IF NOT EXISTS text_style text NOT NULL DEFAULT 'clean' CHECK (text_style ~ '^[a-z]{1,24}$');
