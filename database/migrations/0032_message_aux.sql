-- Auxiliary messages (today: emoji reactions). The relay cannot read message kinds, so the sender
-- flags a reaction with `aux` on the send request. The flag is stored so that unread recounts, the
-- "has the peer replied" gates and report evidence can tell a reaction from a conversation turn.
-- Existing rows are ordinary messages.
ALTER TABLE messages ADD COLUMN aux boolean NOT NULL DEFAULT false;
