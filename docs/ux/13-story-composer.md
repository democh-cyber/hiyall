# Story composer

A story is a 9:16 canvas of words on a colour or gradient, or a caption over a photo. The composer is full-bleed on a rounded canvas; everything that is not the canvas sits in a dock under it. The server rules (allowlists, lifetimes, limits) are in `docs/api/16-pulse-and-media.md`; every limit is enforced there and the app only reflects it.

## Layout

- **Top bar:** a round close button, a character ring (280 at most; it fills as you type, turns amber at 85 percent and shows how many are left) and a **Share** pill. Share is a bordered, quiet pill until there are words (or a finished photo), then a lime-to-mint gradient with a glow; it shrinks while pressed, buzzes lightly when sent and shows "Sharing…" with a spinner.
- **Canvas:** type directly on it. There is no box: the words are large, centred (or left or right), shrink as they get longer, and are drawn in ink or cream, whichever contrasts with the background. The caret blinks and tapping anywhere on the canvas focuses the text. Messages (a limit, a failed upload, "Picked up where you left off.") appear over the canvas, not in a snack bar that would cover the controls.
- **Dock:** two chunky buttons (Photo, Camera; after a photo is picked, Change photo and Remove), then tabs that each open one panel: **Colour**, **Text**, **Vibes**, a clock tab showing the lifetime (**24h**) and a tab showing the audience (**Friends**). With the keyboard up only the tabs stay, and opening one closes the keyboard. In a very short window (a phone on its side) the page scrolls.

## Controls

| Control | What it does |
|---|---|
| Colour | A scrolling row of chunky circular swatches: the six solids and eight gradients. The chosen one grows, gets a ring and settles with a small bounce; the canvas fades between backgrounds. Hidden for a photo story. |
| Text | Left, centre and right alignment (kept on the device only), then six style chips with an "Aa" preview: Clean, Loud, Soft, Glow, Stamp, Type. |
| Vibes | One-tap stickers ("😴 sleepy", "🔥 on fire", "🎧 vibing", "🌧️ gloomy", "📍 out and about", "🥳 celebrating" and more) that add the emoji and word after the text. If it would pass 280 characters nothing is added and the canvas says so. |
| Time | 6h, 12h or 24h pills with a clock icon, 24h by default, and a line saying "Gone 6 hours after you share". |
| Who | 🌍 Everyone, 👥 Followers, 💚 Friends, starting from the member's story audience setting, with a hint that changes with the choice: "Anyone on Hiyall can watch", "Only your followers", "Only your friends". |

Nothing about plans is shown: the app offers 6, 12 and 24 hours and the server decides what a member may use.

## One canvas everywhere

`StoryCanvas` (`lib/shared/story_canvas.dart`) draws a story in the composer, the story viewer and the My stories thumbnails, laid out against a 360 px design width so a thumbnail is a faithful miniature. A story from before text styles has no `textStyle` and is drawn Clean; a background or style name the app does not know (a newer server) is drawn lime or Clean. The viewer shows the time left on your own stories, from `expiresAt`, as My stories does.

## Draft

Every change is saved on the device (the text, background, text style, alignment, audience and lifetime, never the photo) a moment after it is made, per account, and restored when the composer opens again. Sharing clears it. Closing with unsaved words asks "Discard draft?": **Keep editing**, **Save draft** or **Discard**; with only a photo it offers Keep editing or Discard. The system back gesture asks the same.

## Access and motion

Every control is at least 48 by 48 dp and has a screen reader label (for example "sunset background", "Glow text style", "Lasts 6 hours", "Who can see this: Friends", "3 of 280 characters used"). Press feedback is a small scale and a focus ring, never ink. With reduced motion the background change, swatch bounce and press scale are off. The dock grows with the reader's text size up to 1.3 times; the story's own text does not, because it is sized by the canvas.

## Verification

`test/story_composer_test.dart` covers contrast and fitting, drafts, the canvas for old and unknown stories, typing and limits, each panel, the request sent, quota errors, photo mode, accessibility, reduced motion, the keyboard, a short window, wide and narrow windows in both themes, and double text size.
