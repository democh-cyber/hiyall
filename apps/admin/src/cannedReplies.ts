// Starting points for a support reply. They are inserted into the reply box for the operator to edit and are never
// sent automatically. Neutral on purpose: no promises about outcomes, no request for contact details, no off-platform contact.

export interface CannedReply {
  id: string
  title: string
  body: string
}

export const CANNED_REPLIES: CannedReply[] = [
  {
    id: 'thanks',
    title: 'Thanks for writing',
    body: 'Thanks for writing to us. We have read your message and will look into it. We will reply here as soon as we know more.',
  },
  {
    id: 'more-info',
    title: 'Ask for more detail',
    body: 'Thanks for getting in touch. Could you tell us a little more about what happened and when? Please reply here in this conversation.',
  },
  {
    id: 'escalated',
    title: 'Escalated to safety',
    body: 'We have escalated this to our safety team. They will review it. We cannot share the details of what happens next, but you can keep writing to us here if anything changes.',
  },
  {
    id: 'account',
    title: 'Account help',
    body: 'Thanks for telling us about the problem with your account. We are checking it and will reply here. In the meantime you can find your account options under Settings in the app.',
  },
  {
    id: 'bug',
    title: 'Bug received',
    body: 'Thanks for reporting this. We have passed it to the team that builds the app. If you can, tell us which device model and app version you use, and what you were doing when it happened.',
  },
  {
    id: 'resolved',
    title: 'Closing the conversation',
    body: 'We hope this helps. We will close this conversation now. If you need anything else, you can start a new one from the app at any time.',
  },
]
