#!/usr/bin/env python3
"""Generate the implemented API subset from shared architecture vocabulary."""
import copy
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
roadmap = json.loads((root / 'docs/api/openapi-mvp.json').read_text())
schemas = {key: copy.deepcopy(roadmap['components']['schemas'][key]) for key in ['SelfProfile', 'ProfilePatch', 'PrivacySettings', 'PrivacyPatch', 'PublicProfile']}
# Implemented profile extensions; roadmap schemas remain a separate document.
profile_extensions = {
    'headline': {'type': 'string', 'maxLength': 100},
    'quote': {'type': 'string', 'maxLength': 160},
    'currentVibe': {'type': 'string', 'maxLength': 80},
    'interests': {'type': ['array', 'null'], 'maxItems': 10, 'uniqueItems': True, 'items': {'type': 'string', 'minLength': 1, 'maxLength': 40}},
    'profileAccent': {'type': 'string', 'enum': ['', 'lime', 'violet', 'cyan']},
    'profilePattern': {'type': 'string', 'enum': ['', 'glow', 'orbit', 'plain']},
    'avatarFrame': {'type': 'string', 'enum': ['', 'minimal', 'orbit']},
}
language_entry = {'type': 'object', 'additionalProperties': False, 'required': ['code'], 'properties': {
    'code': {'type': 'string', 'minLength': 2, 'maxLength': 35, 'pattern': '^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$'},
    'level': {'type': 'string', 'enum': ['', 'basic', 'conversational', 'fluent', 'native']},
}}
for name in ['SelfProfile', 'ProfilePatch', 'PublicProfile']:
    schemas[name]['properties'].update(copy.deepcopy(profile_extensions))
    schemas[name]['properties']['languages'] = {'type': ['array', 'null'], 'maxItems': 9, 'items': copy.deepcopy(language_entry)}
schemas['ProfilePatch']['properties']['languages'] = {'type': 'array', 'maxItems': 9, 'items': {'anyOf': [copy.deepcopy(language_entry), {'type': 'string', 'minLength': 2, 'maxLength': 35, 'pattern': '^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$'}]}, 'description': 'Structured language entries. Legacy tag strings remain accepted without inferred proficiency.'}
schemas['ProfilePatch']['properties']['interests']['type'] = 'array'
gender_property = {'type': 'string', 'enum': ['', 'woman', 'man', 'nonbinary'], 'description': 'Optional. Empty is unset or prefer not to say. Shown to others only when the gender field audience allows it (default everyone) and used by the gender filter only for members whose audience is everyone. Never returned in search or Nearby results.'}
for name in ['SelfProfile', 'ProfilePatch', 'PublicProfile']:
    schemas[name]['properties']['gender'] = copy.deepcopy(gender_property)
schemas['SelfProfile']['required'].append('gender')
# Whole years of age appear only on another member's profile (never SelfProfile, search or Nearby).
schemas['PublicProfile']['properties']['age'] = {'type': 'integer', 'minimum': 13, 'maximum': 150, 'readOnly': True, 'description': 'Age in whole years, never the birth date or a band. Present only when ALL hold: the age is known (members who joined before birth dates were kept have none), the member\'s age field audience allows you (default everyone; the app has no screen to change it), the profile is not a locked card, and you are not looking at your own profile. Omitted otherwise, never null or 0. Members in the other age band return 404 as for a block. Not part of search or Nearby results or GET /v1/me/profile.'}
for field in ['profileAccent', 'profilePattern', 'avatarFrame']:
    schemas['ProfilePatch']['properties'][field]['enum'].remove('')
for name in ['PrivacySettings', 'PrivacyPatch']:
    audience_fields = schemas[name]['properties']['fieldAudiences']
    audience_fields['properties']['connections'] = {'type': 'string', 'enum': ['everyone', 'friends', 'followers', 'nobody'], 'description': 'Who may open your followers and following lists. New adult accounts start "followers" (anyone who actively follows you, and your friends), so a follower can see who follows you and who you follow; members under 18 start "friends". Your friends list is friends-only whenever this is "followers" (it is read as "friends"). Your profile audience must admit the viewer too.'}
    audience_fields['properties']['vibe'] = {'type': 'string', 'enum': ['everyone', 'friends', 'followers', 'nobody']}
    audience_fields['properties']['gender'] = {'type': 'string', 'enum': ['everyone', 'friends', 'followers', 'nobody']}
    audience_fields['properties']['age'] = {'type': 'string', 'enum': ['everyone', 'friends', 'followers', 'nobody'], 'description': 'Who may see your age in whole years on your profile; default everyone.'}
    audience_fields['properties']['counts'] = {'type': 'string', 'enum': ['everyone', 'friends', 'followers', 'nobody'], 'description': 'Who may see the counts on your profile (friends, following, followers, visitors, stories); default everyone. The connection lists have their own audience, connections.'}
    if name == 'PrivacySettings':
        audience_fields['required'].extend(['vibe', 'connections', 'gender', 'age', 'counts'])
        audience_fields['minProperties'] = len(audience_fields['required'])
for name in ['PrivacySettings', 'PrivacyPatch']:
    schemas[name]['properties']['onlineAudience']['description'] = 'The one presence control in the app. "everyone" (the default) lets people see you are online while you are connected; any other value hides it completely. Last seen is never shown.'
    schemas[name]['properties']['profileAudience']['description'] = 'New accounts start "public" and discoverable; no screen offers a choice for now, but the field stays editable.'
    schemas[name]['properties']['messagesFrom']['description'] = 'Who may start a conversation or message you. New accounts start "everyone": anyone who is not blocked and is in the same age band, with no friendship or follow needed, minors included (within their band). "friends", "followers" and "nobody" are honoured for members who set them through this API; no screen does.'
    schemas[name]['properties']['followPolicy']['description'] = 'New accounts start "everyone": a follow takes effect at once. "approval" holds follows as requests to approve and "nobody" refuses them, for members who set that through this API; no screen does.'
for field in ['verified', 'following', 'friendship', 'reasonCodes', 'sharedInterestCount', 'city', 'region']:
    schemas['PublicProfile']['properties'].pop(field, None)
    if field in schemas['PublicProfile']['required']: schemas['PublicProfile']['required'].remove(field)
# Profile photos (docs/api/20-profile-photos.md). avatarMediaId is the member's own ready, unattached photo uploaded with purpose
# "avatar" (422 VALIDATION on avatarMediaId otherwise); null clears it. coverMediaId is not enabled yet: only null is accepted.
AVATAR_ID_PATTERN = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
schemas['ProfilePatch']['properties']['avatarMediaId'] = {'type': ['string', 'null'], 'format': 'uuid', 'pattern': AVATAR_ID_PATTERN, 'description': 'The mediaId of a photo you uploaded with purpose "avatar" and finished (POST /v1/media/{mediaId}/complete), or null to remove your photo. It must be yours, ready and not used elsewhere, otherwise 422 VALIDATION on avatarMediaId and nothing in the request is applied. Setting it attaches the photo and releases the previous one for deletion in the same transaction; sending the current id changes nothing about the photos. Photo uploads need a finished onboarding, so this is used afterwards.'}
schemas['ProfilePatch']['properties']['coverMediaId'] = {'type': 'null', 'description': 'Cover photos are not implemented; clearing a reference is allowed.'}
avatar_urls = {
    'avatarUrl': {'type': ['string', 'null'], 'format': 'uri', 'readOnly': True, 'description': 'Signed URL of a 640 px thumbnail of the profile photo, valid for an hour; null when there is no photo (or photo storage is not configured). The URL is minted per response and never stored, so refresh it with the profile rather than caching it for long; cache the image bytes by avatarMediaId or the URL path.'},
    'avatarFullUrl': {'type': ['string', 'null'], 'format': 'uri', 'readOnly': True, 'description': 'Signed URL of the full-size (at most 2048 px) profile photo, valid for an hour; null when there is no photo. On another member\'s profile it is null on the locked card, which shows the thumbnail only.'},
}
for name in ['SelfProfile', 'PublicProfile']:
    schemas[name]['properties'].update(copy.deepcopy(avatar_urls))
schemas['SelfProfile']['required'] += ['avatarUrl', 'avatarFullUrl']
schemas['SelfProfile']['properties']['avatarMediaId']['description'] = 'The id of your current profile photo, or null. Set it through PATCH /v1/me/profile.'
def obj(properties, required=None):
    return {'type': 'object', 'additionalProperties': False, 'properties': properties, 'required': list(properties) if required is None else required}
def text(maximum=256):
    return {'type': 'string', 'maxLength': maximum}
def ref(name):
    return {'$ref': f'#/components/schemas/{name}'}
schemas['SocialStats'] = obj({
    'friends': {'type': 'integer', 'minimum': 0, 'readOnly': True},
    'following': {'type': 'integer', 'minimum': 0, 'readOnly': True},
    'followers': {'type': 'integer', 'minimum': 0, 'readOnly': True},
    'visitors': {'type': 'integer', 'minimum': 0, 'readOnly': True, 'description': 'How many different members have opened this profile, all time, counted once each however often they return; never who. Opening a locked card counts; opening your own profile does not.'},
    'stories': {'type': 'integer', 'minimum': 0, 'readOnly': True, 'description': 'How many unexpired stories you may see on this profile (audience, expiry, blocks and age band apply); on your own profile, all your active stories. 0 when none.'},
})
for name in ['SelfProfile', 'PublicProfile']:
    schemas[name]['properties']['socialStats'] = {**ref('SocialStats'), 'description': 'Friends, following and followers count active persisted relationships, excluding inactive and blocked accounts; visitors and stories are described on SocialStats. Shown when the member\'s counts field audience allows the viewer (default everyone); omitted otherwise and never on the locked card. The owner always sees their own.'}
schemas['PublicProfile']['properties']['canSeeConnections'] = {'type': 'boolean', 'readOnly': True, 'description': 'Whether you may open this member\'s followers and following lists (GET /v1/users/{userId}/followers and /following): their profile audience and their connections field audience both admit you, the rule behind 403 CONNECTIONS_PRIVATE. For an adult member (connections defaults to followers) that is true when you actively follow them or are their friend; a pending follow request does not count; for a member under 18 (friends) only friends. Friends lists are not opened by following. Absent on the locked card. The counts on socialStats have their own audience, so a count can show while its list is private.'}
schemas['Meta'] = obj({'requestId': {'type':'string','format':'uuid'}, 'serverTime': {'type':'string','format':'date-time'}})
schemas['ErrorResponse'] = obj({'success': {'const':False}, 'error':obj({'code':text(64),'message':text(256)}), 'meta':ref('Meta')})
schemas['Health'] = obj({'status':{'type':'string','enum':['ok','ready']}})
schemas['Revoked'] = obj({'revoked':{'type':'boolean'}})
schemas['Blocked'] = obj({'blocked':{'type':'boolean'}})
schemas['Session'] = obj({'sessionId':{'type':'string','format':'uuid'},'platform':{'type':'string','enum':['android','ios','web','unknown']},'createdAt':{'type':'string','format':'date-time'},'lastSeenAt':{'type':'string','format':'date-time'},'expiresAt':{'type':'string','format':'date-time'},'current':{'type':'boolean'},'revokedAt':{'type':'string','format':'date-time'}},['sessionId','platform','createdAt','lastSeenAt','expiresAt','current'])
schemas['SessionPage'] = obj({'items':{'type':'array','maxItems':50,'items':ref('Session')},'nextCursor':{'type':['string','null'],'maxLength':2048},'hasMore':{'type':'boolean'}})
schemas['PeopleSearch'] = obj({
    'interests': {'type': 'array', 'maxItems': 10, 'uniqueItems': True, 'items': {'type': 'string', 'minLength': 1, 'maxLength': 40}},
    'languages': {'type': 'array', 'maxItems': 10, 'uniqueItems': True, 'items': {'type': 'string', 'minLength': 2, 'maxLength': 35, 'pattern': '^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$'}},
    'country': {'type': 'string', 'pattern': '^([A-Z]{2})?$', 'maxLength': 2},
    'vibe': {'type': 'string', 'maxLength': 80},
    'ageMin': {'type': 'integer', 'minimum': 13, 'maximum': 99, 'description': 'Inclusive lower age. A plain JSON integer. Works on the private stored birth date; members whose age is unknown never match an age filter. Ages are never returned in search or Nearby results (another member\'s profile shows whole years when its age audience allows).'},
    'ageMax': {'type': 'integer', 'minimum': 13, 'maximum': 99, 'description': 'Inclusive upper age, at least ageMin when both are sent.'},
    'gender': {'type': 'string', 'enum': ['', 'woman', 'man', 'nonbinary'], 'description': 'Empty means any. Matches only members whose gender field audience is everyone and whose gender equals this value.'},
    'online': {'type': 'boolean', 'description': 'True keeps only members whose onlineAudience admits you (same rule as the per-row online flag) and who had session activity within the last 2 minutes. Live realtime connections are per node and not part of the filter, so it can only under-report; every returned row carries the precise flag. false is the same as omitting it. Part of the cursor binding.'},
    'cursor': {'type': 'string', 'maxLength': 2048},
}, [])
schemas['DiscoveryPerson'] = obj({
    key: copy.deepcopy(schemas['PublicProfile']['properties'][key])
    for key in ['userId', 'username', 'displayName', 'avatarUrl', 'headline', 'bio', 'interests', 'languages', 'currentVibe', 'country']
}, ['userId', 'username', 'displayName', 'avatarUrl', 'headline', 'bio'])
online_flag = {'type': 'boolean', 'const': True, 'description': 'Present, and always true, only while this member is online and their onlineAudience admits you (everyone; friends for accepted friends; followers for friends and active followers; nobody never, except yourself). Online means a live realtime connection on this node or session activity within the last 2 minutes. Omitted otherwise: offline, hidden and any other audience look the same. Never false.'}
last_seen_flag = {'type': 'string', 'format': 'date-time', 'description': 'The member\'s latest session activity, rounded DOWN to 5 minutes (UTC, never an exact time). Present only when the member is not online, has been active, and their onlineAudience admits you (last seen has no control of its own and follows it). Omitted otherwise, so a member who hides presence looks exactly like one who was never seen.'}
schemas['DiscoveryPerson']['properties']['sharedInterests'] = {'type': 'array', 'maxItems': 3, 'items': {'type': 'string'}, 'description': 'Up to 3 interests you and this member share, matched case-insensitively and spelled and ordered as you wrote them. Present, possibly empty, exactly when interests is present (the member\'s interests audience is everyone); one batched read of your own interests per page.'}
schemas['DiscoveryPerson']['properties']['online'] = copy.deepcopy(online_flag)
schemas['DiscoveryPerson']['properties']['lastSeenAt'] = copy.deepcopy(last_seen_flag)
schemas['PublicProfile']['properties']['online'] = {**copy.deepcopy(online_flag), 'description': online_flag['description'] + ' Not shown on a locked card.'}
schemas['PublicProfile']['properties']['lastSeenAt'] = {**copy.deepcopy(last_seen_flag), 'description': last_seen_flag['description'] + ' Not shown on a locked card.'}
schemas['PeoplePage'] = obj({'items': {'type': 'array', 'maxItems': 20, 'items': ref('DiscoveryPerson')}, 'nextCursor': {'type': ['string', 'null'], 'maxLength': 2048}})
schemas['NearbyPerson'] = obj({**copy.deepcopy(schemas['DiscoveryPerson']['properties']), 'distanceKm': {'type': 'integer', 'enum': [5, 10, 15, 25, 50, 100], 'description': 'A bucket: the smallest of 5, 10, 15, 25, 50, 100 that is at least the distance between the two stored (grid-rounded) points. A viewer who is a minor sees only 10, 25, 50 and 100. Never a coordinate, grid cell or finer distance.'}}, ['userId', 'username', 'displayName', 'avatarUrl', 'headline', 'bio', 'distanceKm'])
schemas['NearbyPage'] = obj({'items': {'type': 'array', 'maxItems': 20, 'items': ref('NearbyPerson')}, 'nextCursor': {'type': ['string', 'null'], 'maxLength': 2048}})
schemas['NearbySearch'] = obj({
    'radiusKm': {'type': 'integer', 'enum': [5, 10, 15, 25, 50, 100], 'default': 25, 'description': 'Whole kilometres, a plain JSON integer, one of the distance buckets (anything else is 422, so the circle cannot be narrowed below 5 km). A viewer who is a minor is searched at the smallest of 10, 25, 50, 100 that covers it. Send it unchanged with a cursor.'},
    **copy.deepcopy(schemas['PeopleSearch']['properties']),
}, [])
schemas['NearbySearch']['properties']['cursor']['description'] = 'Opaque, signed and expiring after 15 minutes; bound to you, the radius, the filters and your stored point. Changing any of them invalidates it (422 INVALID_CURSOR).'
schemas['LocationUpdate'] = obj({'latitude': {'type': 'number', 'minimum': -90, 'maximum': 90}, 'longitude': {'type': 'number', 'minimum': -180, 'maximum': 180}})
schemas['LocationState'] = obj({'sharing': {'type': 'boolean', 'description': 'True while a stored location is younger than 24 hours.'}, 'updatedAt': {'type': ['string', 'null'], 'format': 'date-time', 'description': 'When the shared point was stored; null unless sharing. Coordinates are never returned.'}})
schemas['LocationStopped'] = obj({'sharing': {'const': False}})
schemas['NearbyState'] = obj({'visible': {'type': 'boolean', 'description': 'The "Show me in Nearby" switch. Off for every new member and for every member under 18 until they turn it on; only visible members are listed in Nearby, and only visible members can search it.'}, 'sharing': {'type': 'boolean', 'description': 'True while a stored location is younger than 24 hours.'}, 'minor': {'type': 'boolean', 'description': 'Whether the server treats you as under 18 (stronger explainer, coarser area, other minors only).'}, 'updatedAt': {'type': ['string', 'null'], 'format': 'date-time'}})
schemas['AgeCheck'] = obj({'birthDate': {'type': 'string', 'format': 'date', 'pattern': '^[0-9]{4}-[0-9]{2}-[0-9]{2}$', 'description': 'The declared birth date, sent as soon as it is chosen. Not stored by this call.'}})
schemas['AgeAllowed'] = obj({'allowed': {'const': True}})
schemas['DevelopmentLogin'] = obj({'userId':{'type':'string','enum':['019a4000-0000-7000-8000-000000000001','019a4000-0000-7000-8000-000000000002','019a4000-0000-7000-8000-0000000000a1'],'description':'Anjali, Niko, and Sam (a fixture whose onboarding is not complete).'}})
schemas['DevelopmentSession'] = obj({'accessToken':{'type':'string','minLength':43,'maxLength':43},'userId':{'type':'string','format':'uuid'},'sessionId':{'type':'string','format':'uuid'},'expiresIn':{'type':'integer','minimum':1800,'maximum':1800}})
# Ids are accepted only in the canonical form the API returns (lowercase, hyphenated); urn:uuid:, braces,
# bare hex and upper case are 404 in a path and 422 in a body.
CANONICAL_ID = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
uuid_t = {'type':'string','format':'uuid','pattern':CANONICAL_ID}
when = {'type':'string','format':'date-time'}
schemas['UserSummary'] = obj({'userId':uuid_t,'username':{'type':'string','pattern':'^[a-z0-9_]{3,30}$'},'displayName':text(80),'avatarUrl':copy.deepcopy(avatar_urls['avatarUrl'])})
schemas['Relationship'] = obj({
    'following': {'type':'string','enum':['none','pending','active'],'description':'Viewer follows the profile owner.'},
    'followedBy': {'type':'boolean'},
    'friendship': {'type':'string','enum':['none','pending_outgoing','pending_incoming','accepted']},
    'friendRequestId': {**uuid_t,'description':'Present while a request is pending, so the client can accept or cancel it.'},
    'canFollow': {'type':'boolean'},
    'canFriendRequest': {'type':'boolean'},
}, ['following','followedBy','friendship','canFollow','canFriendRequest'])
schemas['PublicProfile']['properties']['relationship'] = ref('Relationship')
schemas['PublicProfile']['properties']['locked'] = {'type':'boolean','description':'True when the profile audience excludes the viewer. A locked card carries only identity (name and photo thumbnail), style and relationship.'}
for field in list(schemas['PublicProfile']['required']):
    if field not in ['userId','username','displayName']:
        schemas['PublicProfile']['required'].remove(field)
schemas['PublicProfile']['required'] += ['avatarUrl', 'avatarFullUrl']
schemas['FollowState'] = obj({'following':{'type':'string','enum':['none','pending','active']}})
schemas['FollowerState'] = obj({'follower':{'const':'active'}})
schemas['FriendshipState'] = obj({'friendship':{'const':'none'}})
schemas['Removed'] = obj({'removed':{'type':'boolean'}})
schemas['Cancelled'] = obj({'cancelled':{'type':'boolean'}})
schemas['Read'] = obj({'read':{'type':'boolean'}})
schemas['ReadAll'] = obj({'updated':{'type':'integer','minimum':0}})
schemas['UnreadCount'] = obj({'unreadCount':{'type':'integer','minimum':0,'maximum':99,'description':'Unread activity, counted up to 99.'},'unreadMore':{'type':'boolean','description':'True when more than 99 are unread: show "99+". Absent in answers from older servers, which never exceeded the real count.'}})
schemas['Connection'] = obj({'user':ref('UserSummary'),'since':when,'following':{'type':'string','enum':['none','pending','active'],'description':'Your own follow state on this person, so a followers list can offer Follow back. Present on followers, following, friends and follow-request rows; left out of story viewers.'}},['user','since'])
schemas['Visitor'] = obj({'user':ref('UserSummary'),'firstVisitedAt':{**when,'description':'When this member first opened your profile; later visits do not move it.'},'following':{'type':'string','enum':['none','pending','active'],'description':'Your own follow state on this visitor.'}})
schemas['FriendRequest'] = obj({'requestId':uuid_t,'sender':ref('UserSummary'),'recipient':ref('UserSummary'),'status':{'type':'string','enum':['pending','accepted','declined','cancelled','removed']},'createdAt':when})
schemas['Notification'] = obj({
    'notificationId':uuid_t,
    'type':{'type':'string','enum':['follow','friend_request','reaction','comment','community']},
    'event':{'type':'string','enum':['follow.started','follow.requested','follow.accepted','friend.requested','friend.accepted','post.reacted','post.commented','space.invited','space.requested','space.approved']},
    'actors':{'type':'array','minItems':1,'maxItems':1,'items':ref('UserSummary')},
    'count':{'type':'integer','const':1},
    'targetType':{'type':'string','enum':['profile','request','post','space']},
    'targetId':uuid_t,
    'createdAt':when,
    'readAt':when,
    'text':text(120),
}, ['notificationId','type','event','actors','count','targetType','targetId','createdAt','text'])
page_meta = {'nextCursor':{'type':['string','null'],'maxLength':2048},'hasMore':{'type':'boolean'}}
for name in ['Connection','FriendRequest','Notification','Visitor']:
    props = {'items':{'type':'array','maxItems':50,'items':ref(name)}, **page_meta}
    if name == 'Notification':
        props['unreadCount'] = {'type':'integer','minimum':0,'maximum':99,'description':'Unread activity, counted up to 99.'}
        props['unreadMore'] = {'type':'boolean','description':'True when more than 99 are unread: show "99+".'}
    schemas[name+'Page'] = obj(props)
b64key = {'type':'string','pattern':'^[A-Za-z0-9+/]{43}$','description':'Unpadded base64 32-byte public key'}
b64sig = {'type':'string','pattern':'^[A-Za-z0-9+/]{86}$','description':'Unpadded base64 Ed25519 signature'}
schemas['DeviceRegister'] = obj({'deviceId':uuid_t,'identityKey':b64key,'signingKey':b64key,'signature':{**b64sig,'description':'Ed25519 over "hiyall-device-v1\\n{userId}\\n{deviceId}\\n{identityKey}\\n{signingKey}"'},'platform':{'type':'string','enum':['android','ios','web','linux','unknown']},'displayName':text(60)},['deviceId','identityKey','signingKey','signature'])
schemas['Device'] = obj({'deviceId':uuid_t,'userId':uuid_t,'identityKey':b64key,'signingKey':b64key,'signature':b64sig,'platform':{'type':'string'},'displayName':text(60),'createdAt':when})
schemas['DeviceList'] = obj({'items':{'type':'array','maxItems':10,'items':ref('Device')}})
schemas['SignedKey'] = obj({'keyId':text(64),'publicKey':b64key,'signature':{**b64sig,'description':'Ed25519 over "hiyall-otk-v1\\n{userId}\\n{deviceId}\\n{keyId}\\n{publicKey}"'}})
schemas['KeyUpload'] = obj({'oneTimeKeys':{'type':'array','maxItems':50,'items':ref('SignedKey')},'fallbackKey':ref('SignedKey')},[])
schemas['KeyCount'] = obj({'oneTimeKeyCount':{'type':'integer','minimum':0,'maximum':100},'hasFallbackKey':{'type':'boolean'}},['oneTimeKeyCount'])
schemas['ClaimedKey'] = obj({'deviceId':uuid_t,'keyId':text(64),'publicKey':b64key,'signature':b64sig,'fallback':{'type':'boolean'}})
schemas['ConversationOpen'] = obj({'userId':uuid_t})
schemas['ConversationPeer'] = obj({**copy.deepcopy(schemas['UserSummary']['properties']), 'online': copy.deepcopy(online_flag), 'lastSeenAt': copy.deepcopy(last_seen_flag)}, ['userId', 'username', 'displayName', 'avatarUrl'])
schemas['DirectConversation'] = obj({'conversationId':uuid_t,'peer':ref('ConversationPeer'),'status':{'type':'string','enum':['active','closed']},'createdAt':when,'lastMessageAt':{'type':['string','null'],'format':'date-time'}})
schemas['DirectConversationPage'] = obj({'items':{'type':'array','maxItems':50,'items':ref('DirectConversation')}, **page_meta})
schemas['CiphertextEnvelope'] = obj({'deviceId':uuid_t,'type':{'type':'integer','enum':[0,1],'description':'0 = Olm pre-key message, 1 = Olm message'},'ciphertext':{'type':'string','maxLength':21848,'pattern':'^[A-Za-z0-9+/]+$','description':'Unpadded base64 Olm ciphertext, at most 16 KiB decoded'}})
schemas['EncryptedMessageSend'] = obj({'messageId':uuid_t,'senderDeviceId':uuid_t,'envelopes':{'type':'array','minItems':1,'maxItems':20,'items':ref('CiphertextEnvelope'),'description':'Exactly one per active device of the peer and of the sender other than senderDeviceId; otherwise 409 DEVICES_CHANGED'}})
schemas['MessageAccepted'] = obj({'messageId':uuid_t,'createdAt':when})
schemas['InboxItem'] = obj({'messageId':uuid_t,'conversationId':uuid_t,'senderId':uuid_t,'senderDeviceId':uuid_t,'senderIdentityKey':b64key,'type':{'type':'integer','enum':[0,1]},'ciphertext':{'type':'string'},'createdAt':when})
schemas['Inbox'] = obj({'items':{'type':'array','maxItems':100,'items':ref('InboxItem')}})
schemas['InboxAck'] = obj({'messageIds':{'type':'array','minItems':1,'maxItems':100,'items':uuid_t}})
schemas['Acknowledged'] = obj({'acknowledged':{'type':'integer','minimum':0}})
TERMS_VERSION = '2026-10-01'
schemas['OnboardingState'] = obj({
    'completed': {'type': 'boolean', 'description': 'False until the account has declared it meets the minimum age (13) and accepted the terms. Until then most routes answer 403 ONBOARDING_REQUIRED.'},
    'completedAt': {'type': ['string', 'null'], 'format': 'date-time'},
    'termsVersion': {'type': 'string', 'const': TERMS_VERSION, 'description': 'The current terms version; send it back when completing.'},
})
schemas['OnboardingCompletion'] = obj({
    'birthDate': {'type': 'string', 'format': 'date', 'pattern': '^[0-9]{4}-[0-9]{2}-[0-9]{2}$', 'description': 'Strict ISO date, not in the future, year 1900 or later. Age is computed in UTC. The date is kept privately to place the member in an age band (minor under 18, adult otherwise); the first stored value is final and a later one is ignored. It is never returned, echoed, logged or put in an event. The minimum-age check (13) is a self-declaration, not age assurance, and can be falsified.'},
    'termsVersion': {'type': 'string', 'const': TERMS_VERSION, 'description': 'Must equal the current terms version.'},
})
schemas['UsernameAvailability'] = obj({'available': {'type': 'boolean', 'description': 'True when the name is free or already yours. Generated member_ names are never available.'}})
# Routes an account may use before onboarding is complete; every other authenticated route can answer 403 ONBOARDING_REQUIRED.
ONBOARDING_EXEMPT = {('/v1/me/profile', 'get'), ('/v1/me/profile', 'patch'), ('/v1/me/privacy', 'get'), ('/v1/me/privacy', 'patch'), ('/v1/me/onboarding', 'get'), ('/v1/me/onboarding/complete', 'post'), ('/v1/me/onboarding/age', 'post'), ('/v1/usernames/{username}/availability', 'get'), ('/v1/me/deletion', 'get'), ('/v1/me/deletion', 'post'), ('/v1/me/deletion', 'delete')}
paths = {}
def operation(path, method, response, tag, summary, body=None, parameters=None, public=False, errors=None):
    wrapper = response+'Response'
    schemas[wrapper] = obj({'success':{'const':True},'data':ref(response),'meta':ref('Meta')})
    responses = {'200':{'description':'Successful operation','content':{'application/json':{'schema':ref(wrapper)}}}}
    for status in ['401','403','404','409','412','422','426','428','429','500','503']:
        responses[status] = {'description':('Error 426 UPGRADE_REQUIRED: this app version is older than the minimum the server accepts (X-Client-Version); update the app' if status=='426' else f'Error {status}; no internal details disclosed'),'content':{'application/json':{'schema':ref('ErrorResponse')}}}
    if not public:
        # Sign-in and onboarding outcomes shared by every authenticated operation.
        gated = (path, method) not in ONBOARDING_EXEMPT and not path.startswith('/v1/auth/')
        responses['403']['description'] = 'Error 403. EMAIL_NOT_VERIFIED: a password sign-in whose email is not verified.' + (' ONBOARDING_REQUIRED: finish onboarding first.' if gated else '') + ' Other policy codes are listed on the operation.'
        responses['401']['description'] = 'Error 401 UNAUTHENTICATED: missing, invalid, expired or revoked credentials. APP_CHECK_REQUIRED: the server enforces Firebase App Check (APP_CHECK_ENFORCE=true) and the X-Firebase-AppCheck header is missing or not a valid token.'
        responses['503']['description'] = 'Error 503; includes AUTH_UNAVAILABLE when sign-in keys cannot be fetched and APP_CHECK_UNAVAILABLE when App Check keys cannot. Retry without signing the person out.'
    for status, description in (errors or {}).items():
        responses[status]['description'] = description
    op = {'operationId':method+response+path.replace('/','_').replace('{','').replace('}',''), 'tags':[tag], 'summary':summary,'security':[] if public else [{'bearerAuth':[]}], 'responses':responses}
    if parameters: op['parameters'] = parameters
    if body: op['requestBody'] = {'required':True,'content':{'application/json':{'schema':ref(body)}}}
    paths.setdefault(path,{})[method] = op
match = {'name':'If-Match','in':'header','required':True,'description':'Quoted positive resource version, for example "1".','schema':{'type':'string','maxLength':21,'pattern':'^"[1-9][0-9]{0,18}"$'}}
uid = {'name':'userId','in':'path','required':True,'schema':uuid_t}
sid = {'name':'sessionId','in':'path','required':True,'schema':uuid_t}
for path in ['/health/live','/health/ready']: operation(path,'get','Health','Health','Check service health',public=True)
operation('/dev/session','post','DevelopmentSession','Development','Local-only development session; absent in production','DevelopmentLogin',public=True)
for path,response,patch in [('/v1/me/profile','SelfProfile','ProfilePatch'),('/v1/me/privacy','PrivacySettings','PrivacyPatch')]:
    operation(path,'get',response,'Profile','Read your current settings')
    operation(path,'patch',response,'Profile','Update your settings atomically; limited per account (burst 30, then one every 3 seconds)'+(' ; changing the username starts a 30 day cooldown (the first real name over the generated one is free)' if path=='/v1/me/profile' else ''),patch,[match],errors={
        '429':'Error 429. RATE_LIMITED: too many edits (Retry-After).'+(' USERNAME_COOLDOWN: the username was changed in the last 30 days (Retry-After is the time left).' if path=='/v1/me/profile' else '')})
operation('/v1/users/{userId}/profile','get','PublicProfile','Profile','Read a profile with your relationship; opening it records you as a visitor (once per member, never exposed, not for your own profile, the locked card does count); audiences that exclude you return a locked card; another member\'s age in whole years is included when known and its audience allows you, never on the locked card or your own profile; blocked and inactive accounts, and members in the other age band (minors and adults are kept apart, with AGE_BAND_ISOLATION on), return 404 exactly as a block does',parameters=[uid])
for method in ['post','delete']: operation('/v1/users/{userId}/block',method,'Blocked','Profile','Change a block; both viewing directions are denied while blocked',parameters=[uid])
operation('/v1/me/onboarding','get','OnboardingState','Onboarding','Read whether onboarding is complete; allowed before onboarding')
operation('/v1/me/onboarding/complete','post','OnboardingState','Onboarding','Declare your birth date (13 or over) and accept the current terms; idempotent; needs a chosen name and username; allowed before onboarding. The birth date is stored privately (the first one is final) and puts you in the minor or adult age band; a declared age under 18 also applies the stricter minor defaults once (presence hidden, country shown to friends only)','OnboardingCompletion',errors={
    '403':'Error 403 AGE_REQUIREMENT_NOT_MET: "Hiyall is for people 13 and over." Nothing is stored. A self-declaration is not age assurance and can be falsified. EMAIL_NOT_VERIFIED also applies.',
    '422':'Error 422. VALIDATION: birthDate is not a strict past ISO date from 1900 on, termsVersion is not current, or a field is missing or unknown. PROFILE_INCOMPLETE: "Choose a name and username first." while the generated username or name remains.'})
operation('/v1/me/onboarding/age','post','AgeAllowed','Onboarding','Check a declared birth date before onboarding completes; allowed before onboarding. A date under 13 is refused and the refusal is recorded against the sign-in identity (issuer and subject, no date) for 7 days: every further age check or completion from that identity answers 403 AGE_GATE_COOLDOWN, whatever date is sent. Nothing is stored for an accepted date','AgeCheck',errors={
    '403':'Error 403 AGE_REQUIREMENT_NOT_MET: "Hiyall is for people 13 and over." AGE_GATE_COOLDOWN: this sign-in declared an age under 13 in the last 7 days.',
    '422':'Error 422 VALIDATION: birthDate is not a strict past ISO date from 1900 on, or another field was sent.'})
operation('/v1/usernames/{username}/availability','get','UsernameAvailability','Onboarding','Check a username against the profile grammar; your own name is available; generated member_ names never are; shares the per-account search rate limit; allowed before onboarding',parameters=[{'name':'username','in':'path','required':True,'schema':{'type':'string','minLength':3,'maxLength':30,'pattern':'^[a-z0-9_]{3,30}$'}}],errors={
    '422':'Error 422 VALIDATION: the name does not match the username grammar.',
    '429':'Error 429 RATE_LIMITED: too many checks; retry after the Retry-After header.'})
operation('/v1/discovery/search', 'post', 'PeoplePage', 'Discovery', 'Search discoverable public profiles of every onboarded member in your own age band (no eligibility step; minors and adults never see each other, like a block); only the fields each member shows, OR within a collection and AND across dimensions, plus ageMin/ageMax and gender filters (each filter, age included, matches only members whose audience for that field is everyone); 20 per page, at most 10 pages, principal/query-bound cursors', 'PeopleSearch',errors={
    '422':'Error 422. VALIDATION: unsupported or malformed filter, including ageMin or ageMax that is not an integer from 13 to 99, ageMin above ageMax, or a gender other than woman, man, nonbinary or empty. INVALID_CURSOR: the cursor is tampered, expired, or was issued for other filters, another search or another account.',
    '429':'Error 429 RATE_LIMITED: shared per-account search limit; retry after the Retry-After header. DAILY_LIMIT: more than 300 search pages in a UTC day (Entitlements.SearchPagesPerDay). 422 FILTER_NOT_AVAILABLE: age and gender filters are refused for a viewer under 18, and never narrow candidates who are minors.'})
operation('/v1/me/nearby','get','NearbyState','Nearby','Your "Show me in Nearby" switch and whether a fresh point is stored; never returns coordinates')
operation('/v1/me/nearby','put','NearbyState','Nearby','Turn on "Show me in Nearby" (no body). Stores no location; send one with PUT /v1/me/location. Off by default for everyone, including every member under 18',errors={
    '429':'Error 429 RATE_LIMITED: shares the location limiter; retry after the Retry-After header.'})
operation('/v1/me/nearby','delete','NearbyState','Nearby','Turn "Show me in Nearby" off and delete the stored point in the same transaction; idempotent; you leave everyone\'s results and Nearby closes for you')
operation('/v1/me/location','get','LocationState','Nearby','Whether you are sharing a location now (a stored point younger than 24 hours); never returns coordinates')
operation('/v1/me/location','put','LocationState','Nearby','Share your location: the server rounds both coordinates before storing, to 2 decimal places (about 1.1 km) for adults and 1 decimal place (about 11 km) for minors, decided by your age band when you write, so a precise position is never kept, logged or echoed. Before rounding the point is moved by the member\'s secret daily random offset (up to 2 km, 5 km for minors; rotated each UTC day, stored). Replaces any earlier point; it counts as shared for 24 hours and is deleted after 7 days. Needs "Show me in Nearby" to be on','LocationUpdate',errors={
    '409':'Error 409 NEARBY_OFF: "Turn on Show me in Nearby first."',
    '422':'Error 422 VALIDATION: the body is not exactly {latitude, longitude} as finite numbers in range. LOCATION_IMPLAUSIBLE: the point is more than 1000 km/h (plus 30 km) from the last stored one.',
    '429':'Error 429 RATE_LIMITED: a burst of 3 changes per account, then one every 2 minutes; retry after the Retry-After header (120 seconds). DAILY_LIMIT: more than 5 changes to a different cell in a UTC day (Entitlements.LocationChangesPerDay); a write to the same cell only refreshes the time.'})
operation('/v1/me/location','delete','LocationStopped','Nearby','Stop sharing: deletes the stored point; idempotent; you leave everyone\'s Nearby results immediately')
operation('/v1/discover/nearby','post','NearbyPage','Nearby','People near your stored location, nearest distance bucket first and then by user id: active, onboarded, discoverable and public members in your own age band whose fresh stored point is within the radius of yours, never you, never anyone blocked in either direction. The body takes the same optional filters as people search (interests, languages, country, vibe, ageMin, ageMax, gender, online; OR within a collection, AND across dimensions, matching only members whose field audience is everyone, fieldAudiences.age for the age filter) plus radiusKm; unknown keys are refused. 20 per page, at most 10 pages, cursor bound to you, the radius, the filters and your stored point, expiring after 15 minutes','NearbySearch',errors={
    '409':'Error 409 NEARBY_OFF: "Turn on Show me in Nearby first." You must be visible to search Nearby. LOCATION_NOT_SHARED: "Share your location to see people nearby." You have no stored location younger than 24 hours.',
    '422':'Error 422. VALIDATION: radiusKm is not one of 5, 10, 15, 25, 50, 100, a filter is malformed (ageMin/ageMax must be integers from 13 to 99 with ageMin not above ageMax, gender one of woman, man, nonbinary or empty) or an unknown key was sent (a position is never accepted). INVALID_CURSOR: the cursor is tampered, expired, from another account, or was issued for another radius, other filters or before you moved.',
    '429':'Error 429 RATE_LIMITED: shares the per-account search limit; retry after the Retry-After header. DAILY_LIMIT: more than 200 Nearby queries (pages included) in a UTC day (Entitlements.NearbyQueriesPerDay). 422 FILTER_NOT_AVAILABLE: age and gender filters are refused for a viewer under 18 (and never narrow candidates who are minors).'})
operation('/v1/auth/logout','post','Revoked','Sessions','Revoke the current session and end its realtime connections (closed with 1008)')
operation('/v1/auth/sessions','get','SessionPage','Sessions','List only your sessions that are still signed in, newest first, with a principal-bound cursor: not revoked, and either unexpired or, for a sign-in from the identity provider (which refreshes its tokens), used within the last 30 days',parameters=[{'name':'limit','in':'query','schema':{'type':'integer','minimum':1,'maximum':50,'default':20}},{'name':'cursor','in':'query','schema':text(2048)}])
operation('/v1/auth/sessions/{sessionId}','delete','Revoked','Sessions','Revoke an owned session, expired or not, and end its realtime connections; a revoked sign-in never comes back with a refreshed token; foreign sessions return 404',parameters=[sid])
page_params = [{'name':'limit','in':'query','schema':{'type':'integer','minimum':1,'maximum':50,'default':20}},{'name':'cursor','in':'query','schema':text(2048),'description':'Opaque, principal- and list-bound, expires after 15 minutes.'}]
rid = {'name':'requestId','in':'path','required':True,'schema':uuid_t}
nid = {'name':'notificationId','in':'path','required':True,'schema':uuid_t}
operation('/v1/users/{userId}/follow','post','FollowState','Graph','Follow; instant by default (active); a member whose policy is approval yields pending, "nobody" returns 403 FOLLOW_NOT_ALLOWED; idempotent. Following has no effect on messaging',parameters=[uid])
operation('/v1/users/{userId}/follow','delete','FollowState','Graph','Unfollow or withdraw a pending request; idempotent',parameters=[uid])
operation('/v1/users/{userId}/follow-requests/accept','post','FollowerState','Graph','Approve a pending follower; only the profile owner can',parameters=[uid])
operation('/v1/me/follow-requests','get','ConnectionPage','Graph','Pending followers awaiting your approval',parameters=page_params)
operation('/v1/me/follow-requests/{userId}','delete','Removed','Graph','Decline a pending follower',parameters=[uid])
operation('/v1/me/followers/{userId}','delete','Removed','Graph','Remove an active follower without blocking',parameters=[uid])
operation('/v1/me/visitors','get','VisitorPage','Graph','Who opened your own profile, newest first visit first: owner only (there is no route for anyone else\'s visitors), one row per member with the time of their first visit. Inactive accounts and anyone blocked with you in either direction or in the other age band are left out, so the list can be shorter than the visitors count. Returns at most your VisitorListLimit most recent visitors (200 on Free) across all pages. Visitors are not notified and cannot opt out. Cursor bound to you, expiring after 15 minutes',parameters=page_params,errors={
    '429':'Error 429 RATE_LIMITED: at most 30 reads in a burst, then two a second; retry after the Retry-After header (1 second).'})
operation('/v1/users/{userId}/friend-requests','post','FriendRequest','Graph','Send a friend request under the target requestsFrom policy; crossing requests accept; 7-day cooldown after a decline (429 REQUEST_COOLDOWN, Retry-After the seconds left)',parameters=[uid])
operation('/v1/me/friend-requests','get','FriendRequestPage','Graph','Pending friend requests',parameters=[{'name':'direction','in':'query','schema':{'type':'string','enum':['incoming','outgoing'],'default':'incoming'}}]+page_params)
for action in ['accept','decline']:
    operation('/v1/friend-requests/{requestId}/'+action,'post','FriendRequest','Graph',action.capitalize()+' a request addressed to you; anyone else gets 404',parameters=[rid])
operation('/v1/friend-requests/{requestId}','delete','Cancelled','Graph','Cancel your own pending request',parameters=[rid])
operation('/v1/users/{userId}/friendship','delete','FriendshipState','Graph','Unfriend; idempotent',parameters=[uid])
for kind in ['friends','followers','following']:
    operation('/v1/me/'+kind,'get','ConnectionPage','Graph','Your '+kind,parameters=page_params)
    operation('/v1/users/{userId}/'+kind,'get','ConnectionPage','Graph','Another person\'s '+kind+'; needs profile and connections audience access (403 CONNECTIONS_PRIVATE): an active follower or friend of an adult member may open followers and following, friends only for a minor, and the friends list is friends-only unless the owner chose everyone; blocked, other-age-band and inactive accounts are omitted',parameters=[uid]+page_params)
operation('/v1/notifications','get','NotificationPage','Activity','Your activity, newest first; actors you are blocked with or who are inactive are hidden',parameters=[{'name':'unreadOnly','in':'query','schema':{'type':'boolean'}}]+page_params)
operation('/v1/notifications/unread-count','get','UnreadCount','Activity','Unread activity count')
operation('/v1/notifications/read-all','post','ReadAll','Activity','Mark all activity read')
operation('/v1/notifications/{notificationId}/read','post','Read','Activity','Mark one of your notifications read; idempotent',parameters=[nid])
did = {'name':'deviceId','in':'path','required':True,'schema':uuid_t}
cid = {'name':'conversationId','in':'path','required':True,'schema':uuid_t}
operation('/v1/devices','post','Device','Chat','Register this device\'s public identity; idempotent; 409 DEVICE_CONFLICT (revoked or keys belong to another device: the client makes a new identity) or TOO_MANY_DEVICES; a new device is signalled to the account\'s other devices (realtime event device); the device is linked to the registering auth session and revoked with it; devices unseen for 90 days are revoked; 429 RATE_LIMITED (per account, shared with the device list, revoke, key and inbox routes)','DeviceRegister')
operation('/v1/me/devices','get','DeviceList','Chat','Your active devices')
operation('/v1/devices/{deviceId}','delete','Revoked','Chat','Revoke your device; drops its keys and undelivered ciphertext',parameters=[did])
operation('/v1/devices/{deviceId}/keys','post','KeyCount','Chat','Upload signed one-time keys (at most 100 held) and a fallback key','KeyUpload',parameters=[did])
operation('/v1/devices/{deviceId}/keys','get','KeyCount','Chat','Unclaimed key count for your device',parameters=[did])
operation('/v1/users/{userId}/devices','get','DeviceList','Chat','Another person\'s devices, if their messagesFrom allows you (open by default: anyone not blocked and in your age band; 403 MESSAGES_NOT_ALLOWED when a member set friends, followers or nobody)',parameters=[uid])
operation('/v1/users/{userId}/devices/{deviceId}/claim','post','ClaimedKey','Chat','Claim a one-time key exactly once; falls back to the fallback key when none remain or the device has already handed out 100 one-time keys in the last hour',parameters=[uid,did],errors={
    '429':'Error 429. KEY_CLAIMS_LIMITED: you claimed 10 keys of this device in the last hour; Retry-After is the seconds until your oldest of them is an hour old. RATE_LIMITED: the general per-account limit.'})
operation('/v1/conversations','post','DirectConversation','Chat','Open or reopen the direct conversation with a person. Anyone may message anyone who is not blocked and is in the same age band (a member in the other band, or who blocked you, is 404 as for a block), with no friendship or follow needed. Opening a conversation with someone you have never exchanged a message with uses a tighter budget on top of the general limit: a burst of 10, then one a minute, then 429 RATE_LIMITED with Retry-After 60. Starting a conversation (being the first to open it) also counts against a per-member daily limit (Free: 40 per rolling 24 hours, counted by creation time and never refunded; reopening one never counts), then 429 QUOTA with Retry-After','ConversationOpen',errors={
    '403':'Error 403 MESSAGES_NOT_ALLOWED: the member set messagesFrom to friends, followers or nobody through the API and you do not qualify. EMAIL_NOT_VERIFIED and ONBOARDING_REQUIRED also apply.',
    '429':'Error 429. QUOTA: you have started the day\'s limit of new conversations (Retry-After is when enough of the oldest ones you started leave the 24 hour window); the block, privacy and age-band rules are applied first. RATE_LIMITED: too many new conversations with people you have never messaged (burst 10, then one a minute; Retry-After 60), or the general graph limit (Retry-After 2).'})
operation('/v1/conversations','get','DirectConversationPage','Chat','Your active conversations, most recent first',parameters=page_params)
operation('/v1/conversations/{conversationId}','get','DirectConversation','Chat','One of your conversations',parameters=[cid])
operation('/v1/conversations/{conversationId}/messages','post','MessageAccepted','Chat','Relay one ciphertext per recipient device; the server never receives plaintext; idempotent by messageId; 403 AWAITING_REPLY once you have sent 3 messages (not reactions) in a conversation and the peer has sent none','EncryptedMessageSend',parameters=[cid])
operation('/v1/devices/{deviceId}/inbox','get','Inbox','Chat','Undelivered ciphertext for your device, oldest first',parameters=[did,{'name':'limit','in':'query','schema':{'type':'integer','minimum':1,'maximum':100,'default':50}}])
operation('/v1/devices/{deviceId}/inbox/ack','post','Acknowledged','Chat','Mark delivered; the server deletes the ciphertext','InboxAck',parameters=[did])
# Chat state that the conversation list and badge use.
nullable_when = {'type':['string','null'],'format':'date-time'}
schemas['DirectConversation']['properties'].update({
    'unreadCount':{'type':'integer','minimum':0,'description':'The peer\'s messages after your read pointer.'},
    'readAt':{**nullable_when,'description':'Your read pointer.'},
    'peerReadAt':{**nullable_when,'description':'The peer\'s read pointer; only when both of you have read receipts on and neither restricted the other.'},
    'mutedUntil':{**nullable_when,'description':'Set while you muted this chat; 9999-12-31 means until unmuted. Never shown to the peer.'},
    'sharedInterests':{'type':'array','maxItems':3,'items':{'type':'string','minLength':1,'maxLength':40},'description':'Up to three interests you and the peer both list, matched case-insensitively and spelled and ordered as you wrote them. Empty when nothing is shared or when the peer\'s profile audience or interests audience does not admit you (the same rule as their profile). It never records a profile visit.'},
})
schemas['DirectConversation']['required'] = list(schemas['DirectConversation']['properties'])
schemas['Device']['properties']['lastSeenAt'] = {**when,'description':'Only on your own devices (GET /v1/me/devices), never to peers.'}
schemas['Device']['required'] = [k for k in schemas['Device']['properties'] if k != 'lastSeenAt']
schemas['RevokedCount'] = obj({'revoked':{'type':'integer','minimum':0}})
schemas['ChatUnread'] = obj({'messages':{'type':'integer','minimum':0},'conversations':{'type':'integer','minimum':0}})
schemas['ConversationRead'] = obj({'readAt':{**when,'description':'Read up to this message time; the pointer never moves back.'}})
schemas['ReadPointer'] = obj({'readAt':nullable_when})
schemas['PushToken'] = obj({'provider':{'type':'string','enum':['fcm','apns']},'token':{'type':'string','minLength':8,'maxLength':4096}})
schemas['PushRegistered'] = obj({'registered':{'type':'boolean'}})
operation('/v1/auth/sessions/revoke-others','post','RevokedCount','Sessions','Sign out every other session, including idle sign-ins whose last token expired, end their realtime connections, and refuse any Firebase sign-in from before now that has no session yet; returns how many sessions were revoked')
operation('/v1/conversations/unread','get','ChatUnread','Chat','The Chats badge: unread messages and conversations with any, leaving out muted chats, restricted people and barred pairs')
operation('/v1/conversations/{conversationId}/read','post','ReadPointer','Chat','Move your read pointer forward; your devices are signalled, the peer only when read receipts are on for both','ConversationRead',parameters=[cid])
operation('/v1/devices/{deviceId}/push','put','PushRegistered','Chat','Attach a push token to your device (a token moved from another device is detached from it). Use provider fcm on Android and iOS (the APNs key lives in the Firebase console); apns is accepted but nothing is delivered through it. Pushes carry no message content: title Hiyall, body New message, data {kind, conversationId}','PushToken',parameters=[did])
operation('/v1/devices/{deviceId}/push','delete','PushRegistered','Chat','Remove your device\'s push token',parameters=[did])
# Push notifications (docs/api/23-push-notifications.md): the server pushes through FCM (Android and iOS); provider apns is accepted but not delivered.
schemas['NotificationPrefs'] = obj({'chat':{'type':'boolean','description':'New messages. Default true.'},'social':{'type':'boolean','description':'Friend requests, new followers, follow requests and their acceptance, space invitations. Default true.'}})
schemas['NotificationPrefsPatch'] = obj({'chat':{'type':'boolean'},'social':{'type':'boolean'}},[])
operation('/v1/me/notifications','get','NotificationPrefs','Profile','Your push notification choices; both are on until you change them')
operation('/v1/me/notifications','patch','NotificationPrefs','Profile','Change one or both push choices (a key left out keeps its value; at least one is required). Enforced on the server when it decides to push; muting a chat or a person applies on top','NotificationPrefsPatch')

# Safety: mute, restrict, chat mute, control lists and reports (docs/api/14-safety-controls.md).
schemas['MuteRequest'] = obj({'until':{**nullable_when,'description':'A future time; omitted or null mutes until removed. Echoed in UTC.'}},[])
schemas['MuteState'] = obj({'muted':{'type':'boolean'},'until':nullable_when})
schemas['RestrictState'] = obj({'restricted':{'type':'boolean'},'until':{'type':'null'}})
schemas['Control'] = obj({'user':ref('UserSummary'),'since':when,'until':{**when,'description':'Only on a mute with an end.'}},['user','since'])
schemas['ControlPage'] = obj({'items':{'type':'array','maxItems':50,'items':ref('Control')}, **page_meta})
report_targets = ['user','conversation','message','post','comment','story','space','space_entry']
report_reasons = ['spam','harassment','scam','hate','threats','sexual_content','violence','self_harm','underage','impersonation','copyright','other']
schemas['ReportEvidence'] = obj({'messageId':uuid_t,'text':{'type':'string','minLength':1,'maxLength':4000},'sentAt':when,'fromMe':{'type':'boolean','description':'Ignored; the server sets sender and time from the relay\'s records.'}},['messageId','text','sentAt'])
schemas['NewReport'] = obj({'targetType':{'type':'string','enum':report_targets},'targetId':uuid_t,'reasonCode':{'type':'string','enum':report_reasons},'description':text(1000),'evidence':{'type':'array','maxItems':10,'items':ref('ReportEvidence'),'description':'Only for conversation and message reports, and only with disclosureConsent.'},'disclosureConsent':{'type':'boolean'},'block':{'type':'boolean','description':'Also block the subject.'}},['targetType','targetId','reasonCode'])
schemas['ReportSubject'] = obj({'userId':uuid_t,'username':{'type':'string','pattern':'^([a-z0-9_]{3,30})?$'},'displayName':text(80)},None)
schemas['ReportSubject']['description'] = 'username and displayName are empty strings when you may not know who the subject is (another age band, or not onboarded).'
schemas['Report'] = obj({'reportId':uuid_t,'targetType':{'type':'string','enum':report_targets},'targetId':uuid_t,'subject':ref('ReportSubject'),'reasonCode':{'type':'string','enum':report_reasons},'status':{'type':'string','enum':['open','actioned','dismissed']},'createdAt':when,'resolvedAt':nullable_when})
schemas['ReportPage'] = obj({'items':{'type':'array','maxItems':50,'items':ref('Report')}, **page_meta})
schemas['ReportCreated'] = obj({'report':ref('Report'),'duplicate':{'type':'boolean'},'blocked':{'type':'boolean'}})
for control, state in [('mute','MuteState'),('restrict','RestrictState')]:
    summary = {'mute':'Mute a member until a time or until removed: their posts and stories leave your Pulse and their activity and pushes are silenced','restrict':'Restrict a member: activity and pushes silenced, their chats leave your badge, receipts and typing off both ways, their comments on your posts visible only to them'}[control]
    operation('/v1/users/{userId}/'+control,'post',state,'Safety',summary+'; never visible to them. 422 for yourself; 404 for unknown, inactive, not onboarded or other-age-band members',('MuteRequest' if control=='mute' else None),parameters=[uid])
    if control == 'mute':
        paths['/v1/users/{userId}/mute']['post']['requestBody']['required'] = False
    operation('/v1/users/{userId}/'+control,'delete',state,'Safety','Remove your '+control+'; idempotent',parameters=[uid])
operation('/v1/conversations/{conversationId}/mute','post','MuteState','Safety','Mute your side of a chat until a time or until removed: no push and out of the unread badge; never shown to the peer','MuteRequest',parameters=[cid])
paths['/v1/conversations/{conversationId}/mute']['post']['requestBody']['required'] = False
operation('/v1/conversations/{conversationId}/mute','delete','MuteState','Safety','Unmute your side of a chat',parameters=[cid])
for kind in ['blocked','muted','restricted']:
    operation('/v1/me/'+kind,'get','ControlPage','Safety','Your '+kind+' accounts, newest first; expired mutes and inactive accounts omitted'+('' if kind=='blocked' else ', and members in the other age band or not onboarded'),parameters=page_params)
operation('/v1/reports','post','ReportCreated','Safety','Report a member, chat, message, post, comment, story, space or space entry; 201 for a new report, 200 with duplicate true while your earlier report of the same target is open. Evidence is opt-in decrypted text you chose. A report against a member you may not know is accepted but names nobody','NewReport',errors={
    '429':'Error 429 RATE_LIMITED: a burst of 10 reports, then one a minute (Retry-After 60).'})
paths['/v1/reports']['post']['responses']['201'] = copy.deepcopy(paths['/v1/reports']['post']['responses']['200'])
operation('/v1/me/reports','get','ReportPage','Safety','Your own reports and their status',parameters=page_params)

# Pulse: photos, posts, feed, reactions, comments, saves and stories (docs/api/16-pulse-and-media.md).
media_types = ['image/jpeg','image/png','image/webp']
schemas['MediaUploadRequest'] = obj({'purpose':{'type':'string','enum':['post','story','avatar'],'description':'avatar is for a profile photo, attached through PATCH /v1/me/profile (avatarMediaId); post and story photos are attached when the post or story is created.'},'contentType':{'type':'string','enum':media_types},'sizeBytes':{'type':'integer','minimum':1,'maximum':15*1024*1024}})
schemas['MediaUpload'] = obj({'mediaId':uuid_t,'uploadUrl':{'type':'string','format':'uri','description':'Signed PUT URL valid for 15 minutes. It signs the content type and the exact body size (sizeBytes): the store refuses a body of any other length (403). Send the bytes as the raw body; the length is not a header to set.'},'method':{'const':'PUT'},'headers':{'type':'object','additionalProperties':{'type':'string'},'description':'Headers to send with the PUT: only Content-Type. Content-Length is signed into the URL but is never listed; HTTP clients set it from the body.'},'expiresAt':{**when,'description':'The upload URL lasts 15 minutes; the pending upload expires after an hour.'}})
schemas['MediaView'] = obj({'mediaId':uuid_t,'url':{'type':'string','format':'uri','description':'Signed GET URL valid for an hour.'},'thumbUrl':{'type':'string','format':'uri'},'width':{'type':'integer','minimum':0},'height':{'type':'integer','minimum':0}})
schemas['MediaReady'] = obj({**copy.deepcopy(schemas['MediaView']['properties']),'status':{'const':'ready'}})
audiences = {'type':'string','enum':['public','followers','friends']}
reaction_t = {'type':'string','enum':['heart','fire','laugh','wow','sad']}
schemas['NewPost'] = obj({'body':text(2200),'audience':audiences,'mediaIds':{'type':'array','maxItems':10,'uniqueItems':True,'items':uuid_t}},['audience'])
schemas['NewPost']['description'] = 'Write something or add a photo (or both). Text may span lines; other control characters are refused (422).'
schemas['Post'] = obj({'postId':uuid_t,'author':ref('UserSummary'),'body':text(2200),'audience':audiences,'createdAt':when,'editedAt':nullable_when,'media':{'type':'array','maxItems':10,'items':ref('MediaView')},'reactionCount':{'type':'integer','minimum':0},'commentCount':{'type':'integer','minimum':0},'myReaction':{'anyOf':[reaction_t,{'type':'null'}]},'saved':{'type':'boolean'},'mine':{'type':'boolean'}})
schemas['PostPage'] = obj({'items':{'type':'array','maxItems':50,'items':ref('Post')}, **page_meta})
schemas['ReactionSet'] = obj({'reaction':reaction_t})
schemas['ReactionState'] = obj({'reaction':{'anyOf':[reaction_t,{'type':'null'}]}})
schemas['SavedState'] = obj({'saved':{'type':'boolean'}})
schemas['Deleted'] = obj({'deleted':{'type':'boolean'}})
schemas['NewComment'] = obj({'body':{'type':'string','minLength':1,'maxLength':1000},'parentId':{'type':['string','null'],'format':'uuid','pattern':CANONICAL_ID}},['body'])
schemas['Comment'] = obj({'commentId':uuid_t,'postId':uuid_t,'author':ref('UserSummary'),'parentId':{'type':['string','null'],'format':'uuid'},'body':{'type':'string','minLength':1,'maxLength':1000},'createdAt':when,'mine':{'type':'boolean'},'canDelete':{'type':'boolean'}})
schemas['CommentPage'] = obj({'items':{'type':'array','maxItems':50,'items':ref('Comment')}, **page_meta})
backgrounds = ['lime','lilac','pink','mint','peach','ink','sunset','bubblegum','aurora','ocean','grape','mango','midnight','freshmint']
text_styles = ['clean','loud','soft','glow','stamp','type']
story_lifetimes = [6,12,24]
schemas['NewStory'] = obj({'body':text(280),'background':{'type':'string','enum':backgrounds,'default':'lime','description':'The six solid colours (lime, lilac, pink, mint, peach, ink) and the gradients. A client that meets a name it does not know draws lime.'},'textStyle':{'type':'string','enum':text_styles,'default':'clean','description':'How the words are drawn; clients that predate it send none and get clean.'},'lifetimeHours':{'type':['integer','null'],'minimum':1,'maximum':8760,'default':24,'examples':story_lifetimes,'description':'How long the story stays up, in hours. Which hours a member may choose are their entitlements (6, 12 and 24 for everyone today); any other number is refused with 422 VALIDATION and nothing is stored. Omitted or null means 24.'},'mediaId':{'type':['string','null'],'format':'uuid','pattern':CANONICAL_ID},'audience':audiences},['audience'])
schemas['NewStory']['description'] = 'A photo or some words (or both); lives for lifetimeHours (24 when left out).'
schemas['StoryCreated'] = obj({'storyId':uuid_t})
schemas['Story'] = obj({'storyId':uuid_t,'body':text(280),'background':{'type':'string','enum':backgrounds},'textStyle':{'type':'string','enum':text_styles,'description':'Always present; stories made before text styles existed are clean. A newer server may add styles: draw an unknown one as clean.'},'media':{'anyOf':[ref('MediaView'),{'type':'null'}]},'audience':audiences,'createdAt':when,'expiresAt':when,'seen':{'type':'boolean'},'viewCount':{'type':'integer','minimum':0,'maximum':99,'description':'Only on your own stories. Counted up to 99.'},'viewCountMore':{'type':'boolean','description':'Only on your own stories, and only when true: more than 99 members saw it, show "99+".'}},['storyId','body','background','textStyle','media','audience','createdAt','expiresAt','seen'])
schemas['StoryGroup'] = obj({'author':ref('UserSummary'),'stories':{'type':'array','minItems':1,'maxItems':100,'items':ref('Story')},'allSeen':{'type':'boolean'},'mine':{'type':'boolean'},'latest':when})
schemas['StoryPage'] = obj({'items':{'type':'array','maxItems':50,'items':ref('Story')}, **page_meta})
schemas['StoryTray'] = obj({'items':{'type':'array','items':ref('StoryGroup')}})
schemas['Viewed'] = obj({'viewed':{'type':'boolean'}})
mid = {'name':'mediaId','in':'path','required':True,'schema':uuid_t}
pid = {'name':'postId','in':'path','required':True,'schema':uuid_t}
cmid = {'name':'commentId','in':'path','required':True,'schema':uuid_t}
stid = {'name':'storyId','in':'path','required':True,'schema':uuid_t}
operation('/v1/media/uploads','post','MediaUpload','Pulse','Start a photo upload (purpose post, story or avatar; same size and type limits for all): returns a signed PUT URL that pins the content type and the exact size. Per member: at most 50 pending uploads, at most 50 slots and 300 MiB of declared size per rolling 24 hours for every purpose together (counted by creation time whatever became of the upload), and 2 GiB of stored photos; 503 MEDIA_UNAVAILABLE without storage','MediaUploadRequest',errors={
    '429':'Error 429. QUOTA: the day\'s upload slots or bytes are used (Retry-After is when enough of your oldest slots leave the 24 hour window), or the photo storage is full (no Retry-After: delete posts or stories to free space). RATE_LIMITED: 50 uploads are pending (Retry-After is when the oldest expires), or the per-account limiter (Retry-After 5).'})
operation('/v1/media/{mediaId}/complete','post','MediaReady','Pulse','Process an uploaded photo: re-encoded without metadata into full and thumbnail variants; 415 UNSUPPORTED_MEDIA when it cannot be read',parameters=[mid])
operation('/v1/feed','get','PostPage','Pulse','Posts you may see, newest first: your circle (yourself, people you follow and friends) for following, recent public posts for everyone; muted and blocked accounts and the other age band never appear',parameters=[{'name':'mode','in':'query','schema':{'type':'string','enum':['following','everyone'],'default':'following'}}]+page_params)
operation('/v1/posts','post','Post','Pulse','Publish a post with up to 10 of your own ready, unattached post photos (409 MEDIA_NOT_READY otherwise). At most 20 posts per rolling 24 hours, counted by creation time including deleted posts and text-only posts','NewPost',errors={
    '429':'Error 429. QUOTA: the day\'s 20 posts are used (Retry-After is when your oldest post in the window leaves it). RATE_LIMITED: the per-account limiter (Retry-After 5).'})
operation('/v1/posts/{postId}','get','Post','Pulse','A post you may see; otherwise 404',parameters=[pid])
operation('/v1/posts/{postId}','delete','Deleted','Pulse','Delete your post',parameters=[pid])
operation('/v1/posts/{postId}/reaction','put','ReactionSet','Pulse','Set your one reaction on a post','ReactionSet',parameters=[pid])
operation('/v1/posts/{postId}/reaction','delete','ReactionState','Pulse','Remove your reaction',parameters=[pid])
for method in ['put','delete']:
    operation('/v1/posts/{postId}/save',method,'SavedState','Pulse',('Save' if method=='put' else 'Unsave')+' a post you may see; idempotent',parameters=[pid])
operation('/v1/posts/{postId}/comments','get','CommentPage','Pulse','Comments on a post you may see, oldest first',parameters=[pid]+page_params)
operation('/v1/posts/{postId}/comments','post','Comment','Pulse','Comment or reply (parentId); the post\'s comment setting applies (403 COMMENTS_NOT_ALLOWED)','NewComment',parameters=[pid])
operation('/v1/comments/{commentId}','delete','Deleted','Pulse','Delete your comment, or any comment on your post',parameters=[cmid])
operation('/v1/users/{userId}/posts','get','PostPage','Pulse','A member\'s posts you may see, newest first',parameters=[uid]+page_params)
operation('/v1/me/saved','get','PostPage','Pulse','Posts you saved and can still see, most recently saved first',parameters=page_params)
operation('/v1/stories','post','StoryCreated','Pulse','Publish a story; it stays up for lifetimeHours (6, 12 or 24, default 24). At most 30 stories per rolling 24 hours, counted by creation time including deleted stories and text-only stories','NewStory',errors={
    '422':'Error 422 VALIDATION: the field named is not acceptable (an unknown background or textStyle, a lifetimeHours the member does not have, no words and no photo). Nothing is stored and no limit is used.',
    '429':'Error 429. QUOTA: the day\'s 30 stories are used (Retry-After is when your oldest story in the window leaves it). RATE_LIMITED: the per-account limiter (Retry-After 5).'})
operation('/v1/stories/tray','get','StoryTray','Pulse','Active stories you may see, grouped by author: your own first, then unseen, newest first; at most each author\'s newest 100 and 1500 in all')
operation('/v1/me/stories','get','StoryPage','Pulse','Your own active stories (not deleted, not yet expired), newest first, each with viewCount: how many members saw it, counted as the viewers list shows them (inactive accounts and anyone blocked with you or in the other age band are left out). Only ever the caller\'s own; cursor bound to you, expiring after 15 minutes',parameters=page_params,errors={
    '429':'Error 429 RATE_LIMITED: at most 30 reads in a burst, then two a second; retry after the Retry-After header (5 seconds).'})
operation('/v1/users/{userId}/stories','get','StoryPage','Pulse','Another member\'s active stories that you may watch (their audience, blocks, the age band and inactive accounts apply; exactly what the stories count on their profile counts), newest first, each with whether you have seen it. Empty for a member you cannot see. Cursor bound to you and that member, expiring after 15 minutes',parameters=[uid]+page_params,errors={
    '429':'Error 429 RATE_LIMITED: at most 30 reads in a burst, then two a second; retry after the Retry-After header (5 seconds).'})
operation('/v1/stories/{storyId}','delete','Deleted','Pulse','Delete your story; someone else\'s, an unknown or an already deleted story is 404',parameters=[stid])
operation('/v1/stories/{storyId}/view','post','Viewed','Pulse','Record that you viewed a story you may see; once per viewer; your own are not counted',parameters=[stid])
operation('/v1/stories/{storyId}/viewers','get','ConnectionPage','Pulse','Who viewed your story, most recent first; authors only (anyone else, and a deleted story, is 404); inactive accounts and anyone blocked with you or in the other age band are left out',parameters=[stid]+page_params)
for endpoint in ['/v1/media/uploads','/v1/posts','/v1/posts/{postId}/comments','/v1/stories']:
    paths[endpoint]['post']['responses']['201']=paths[endpoint]['post']['responses'].pop('200')
for code, description in [('413','Error 413 TOO_LARGE: photos can be up to 15 MB.'),('415','Error 415 UNSUPPORTED_MEDIA: JPEG, PNG or WebP only.')]:
    paths['/v1/media/uploads']['post']['responses'][code] = {'description':description,'content':{'application/json':{'schema':ref('ErrorResponse')}}}
paths['/v1/media/{mediaId}/complete']['post']['responses']['422'] = {'description':'Error 422 UPLOAD_REJECTED: the photo can\'t be used. Whatever the reason (the upload scanner is not told to the member), the photo is never shown, the response does not say why, and the account may be restricted pending review. Not retryable with the same photo.','content':{'application/json':{'schema':ref('ErrorResponse')}}}
paths['/v1/media/{mediaId}/complete']['post']['responses']['503'] = {'description':'Error 503 SCAN_UNAVAILABLE: the upload scanner could not answer. The upload stays pending and unseen; retry in a moment.','content':{'application/json':{'schema':ref('ErrorResponse')}}}
paths['/v1/media/{mediaId}/complete']['post']['responses']['415'] = {'description':'Error 415 UNSUPPORTED_MEDIA: the photo could not be read.','content':{'application/json':{'schema':ref('ErrorResponse')}}}
# Encrypted chat attachments (docs/api/21-chat-attachments.md): opaque ciphertext blobs in a separate bucket.
bid = {'name':'blobId','in':'path','required':True,'schema':uuid_t}
ct_sha = {'type':'string','minLength':44,'maxLength':44,'pattern':'^[A-Za-z0-9+/]{43}=$','description':'Standard padded base64 of the 32-byte SHA-256 of the whole ciphertext object.'}
schemas['EncryptedMessageSend']['properties']['blobIds'] = {'type':'array','maxItems':4,'uniqueItems':True,'items':uuid_t,'description':'Encrypted attachments this message claims: uploaded (POST /v1/blobs/{blobId}/complete), unexpired, not yet in a message, uploaded by you in this conversation. Any mismatch, unknown and foreign ids included, rolls the whole message back with 409 BLOB_NOT_READY. Linking starts the 30 day retention. The sender must pass the same images gate as for upload slots (403 ATTACHMENTS_NOT_ALLOWED). A retry of an already stored messageId is answered as before and links nothing.'}
# Reactions (docs/api/24-chat-reactions-and-replies.md): a relay-visible hint, because the server cannot read message kinds.
schemas['EncryptedMessageSend']['properties']['aux'] = {'type':'string','enum':['reaction'],'description':'Optional. Marks the message as an emoji reaction rather than a conversation turn. The relay then does not count it as unread for the peer, does not push, does not move the conversation in the list and does not advance the sender read pointer; it still signals the realtime inbox event and passes every gate (block, age band, messagesFrom, exact device set, idempotency, the send limiter). Each envelope is at most 2048 bytes decoded (413 TOO_LARGE), at most 60 per sender per conversation per 10 minutes sustained (429 RATE_LIMITED with Retry-After), no blobIds. Omitted for ordinary messages and by older apps. A sender who sets it wrongly only makes their own message quieter for the peer.'}
paths['/v1/conversations/{conversationId}/messages']['post']['responses']['413'] = {'description':'Error 413 TOO_LARGE: a reaction (aux) envelope is over 2048 bytes.','content':{'application/json':{'schema':ref('ErrorResponse')}}}
schemas['ReportEvidence']['properties']['attachments'] = {'type':'array','maxItems':4,'items':obj({'blobIds':{'type':'array','minItems':1,'maxItems':4,'uniqueItems':True,'items':uuid_t,'description':'Blobs of this evidence message in the reported conversation; any other id is 422 VALIDATION and the report is not stored.'},'descriptor':{'type':'object','additionalProperties':True,'description':'The decrypted attachment descriptor, including its key, shared by the reporter under disclosureConsent. At most 4 KiB; the server keeps it as given and never interprets it.'}}),'description':'Encrypted images of this message the reporter chose to share. The named blobs are held against deletion (retention, uploader delete, block, account deletion) while the report keeps them. Staff only ever see blob ids, sizes and SHA-256 hashes in the moderation tool.'}
schemas['ChatBlobRequest'] = obj({'role':{'type':'string','enum':['full','thumb']},'sizeBytes':{'type':'integer','minimum':32,'maximum':4194304,'description':'Exact ciphertext size. At most 4194304 (4 MiB) for full and 262144 (256 KiB) for thumb, otherwise 413 TOO_LARGE; under 32 is 422.'},'ctSha256':ct_sha})
schemas['ChatBlobSlot'] = obj({'blobId':uuid_t,'uploadUrl':{'type':'string','format':'uri','description':'Signed PUT URL valid for 15 minutes. It signs the content type, the SHA-256 header and the exact body size (sizeBytes): the object store refuses a body with another checksum (400 BadDigest), another length or a request without the headers (403). Content-Length is signed but never listed in headers; HTTP clients set it from the body.'},'method':{'const':'PUT'},'headers':obj({'Content-Type':{'const':'application/octet-stream'},'x-amz-checksum-sha256':ct_sha},['Content-Type','x-amz-checksum-sha256']),'expiresAt':when})
schemas['ChatBlobState'] = obj({'blobId':uuid_t,'state':{'const':'uploaded'}})
schemas['ChatBlobUrl'] = obj({'url':{'type':'string','format':'uri','description':'Signed GET URL valid for 5 minutes; ask again when needed.'},'expiresAt':when,'sizeBytes':{'type':'integer','minimum':32,'maximum':4194304,'description':'Ciphertext size.'}})
operation('/v1/conversations/{conversationId}/blobs','post','ChatBlobSlot','Chat','Reserve an upload slot for one end-to-end encrypted attachment blob (ciphertext the server cannot read; role full or thumb). You must be in an active conversation, not blocked or in the other age band, allowed to message the peer, and the peer must have replied in it or be your friend. Per member: at most 100 blobs and 300 MiB per rolling 24 hours (counted by creation time, deleting does not refund), at most 10 pending. 503 CHAT_MEDIA_UNAVAILABLE without chat storage','ChatBlobRequest',parameters=[cid],errors={
    '403':'Error 403 ATTACHMENTS_NOT_ALLOWED: the peer has not replied and you are not friends. MESSAGES_NOT_ALLOWED: the peer\'s messagesFrom setting refuses you. EMAIL_NOT_VERIFIED and ONBOARDING_REQUIRED also apply.',
    '404':'Error 404: not a member, a blocked or other-age-band pair, or a closed conversation.',
    '429':'Error 429. QUOTA: the daily blob or byte quota is used (Retry-After is when enough of your oldest blobs leave the 24 hour window). RATE_LIMITED: 10 uploads are pending (Retry-After is when the oldest expires), or the per-account limiter.',
    '503':'Error 503 CHAT_MEDIA_UNAVAILABLE: chat storage is not configured or failed.'})
paths['/v1/conversations/{conversationId}/blobs']['post']['responses']['201'] = paths['/v1/conversations/{conversationId}/blobs']['post']['responses'].pop('200')
paths['/v1/conversations/{conversationId}/blobs']['post']['responses']['413'] = {'description':'Error 413 TOO_LARGE: over the role\'s ciphertext cap (full 4 MiB, thumb 256 KiB).','content':{'application/json':{'schema':ref('ErrorResponse')}}}
operation('/v1/blobs/{blobId}/complete','post','ChatBlobState','Chat','Finish an upload: the stored object must be exactly the declared size. Idempotent for your own blob; a wrong size deletes the object and kills the slot (409 BLOB_SIZE_MISMATCH, ask for a new slot); no object yet is 409 BLOB_NOT_READY. An uploaded blob that no message claims expires an hour after completion',parameters=[bid],errors={
    '404':'Error 404: not your blob, an unknown id, or a closed or barred conversation.',
    '409':'Error 409. BLOB_NOT_READY: nothing was uploaded to the signed URL yet. BLOB_SIZE_MISMATCH: the stored size is not the declared one; the object was removed.',
    '503':'Error 503 CHAT_MEDIA_UNAVAILABLE: chat storage is not configured or failed.'})
paths['/v1/blobs/{blobId}/complete']['post']['responses']['410'] = {'description':'Error 410 BLOB_EXPIRED: the slot or blob expired or was deleted.','content':{'application/json':{'schema':ref('ErrorResponse')}}}
operation('/v1/conversations/{conversationId}/blobs/{blobId}/url','get','ChatBlobUrl','Chat','A short-lived signed GET for a blob that is uploaded, sent in a message and unexpired, for either member of an active conversation who is not barred from the peer (muting or restricting the sender does not matter). Responses are Cache-Control no-store. A blob that is not sent yet is 404 for the peer and 409 BLOB_NOT_READY for its uploader',parameters=[cid,bid],errors={
    '404':'Error 404: not a member, a barred pair, a closed conversation, an unknown blob, or someone else\'s unsent blob.',
    '409':'Error 409 BLOB_NOT_READY: your own blob is not sent yet.',
    '503':'Error 503 CHAT_MEDIA_UNAVAILABLE: chat storage is not configured or failed.'})
paths['/v1/conversations/{conversationId}/blobs/{blobId}/url']['get']['responses']['410'] = {'description':'Error 410 BLOB_EXPIRED: past its 30 days, deleted, or its chat was blocked.','content':{'application/json':{'schema':ref('ErrorResponse')}}}
operation('/v1/blobs/{blobId}','delete','Deleted','Chat','Delete your own blob (any state); the object is removed at once, or by the hourly clean-up if storage fails. Idempotent. A blob held as evidence in a report is left alone and the answer is the same. Someone else\'s blob or an unknown id is 404',parameters=[bid],errors={
    '503':'Error 503 CHAT_MEDIA_UNAVAILABLE: chat storage is not configured.'})
# Phase 6: shared spaces for every onboarded member (server-readable discussions).
space_input = {'kind':{'type':'string','enum':['community','moment','event']},'title':{**text(80),'minLength':1},'description':text(2000),'rules':text(2000),'visibility':{'type':'string','enum':['public','private','invite']},'parentId':{'type':['string','null'],'format':'uuid','pattern':CANONICAL_ID},'capacity':{'type':'integer','minimum':2,'maximum':10000},'startsAt':{'type':['string','null'],'format':'date-time'},'endsAt':{'type':['string','null'],'format':'date-time'},'timezone':text(100),'location':text(240)}
schemas['NewSpace']=obj(copy.deepcopy(space_input),['kind','title','visibility','capacity'])
schemas['SharedSpace']=obj({**copy.deepcopy(space_input),'spaceId':uuid_t,'owner':ref('UserSummary'),'status':{'type':'string','enum':['open','closed','archived']},'memberCount':{'type':'integer','minimum':1},'myRole':{'type':'string','enum':['','owner','admin','moderator','member']},'myState':{'type':'string','enum':['','active','pending','invited','banned']},'myRsvp':{'type':'string','enum':['','going','interested']},'canDiscuss':{'type':'boolean'},'createdAt':when})
schemas['SpaceMember']=obj({'user':ref('UserSummary'),'role':{'type':'string','enum':['owner','admin','moderator','member']},'state':{'type':'string','enum':['active','pending','invited','banned']},'rsvp':{'type':'string','enum':['going','interested']},'createdAt':when})
schemas['SpaceEntry']=obj({'entryId':uuid_t,'author':ref('UserSummary'),'body':{**text(2000),'minLength':1},'createdAt':when,'canDelete':{'type':'boolean'}})
for item in ['SharedSpace','SpaceMember','SpaceEntry']:
    schemas[item+'Page']=obj({'items':{'type':'array','maxItems':50,'items':ref(item)},'nextCursor':{'type':['string','null'],'maxLength':2048},'hasMore':{'type':'boolean'}})
schemas['SpaceMembership']=obj({'rsvp':{'type':'string','enum':['going','interested']}},[])
schemas['SpaceStatus']=obj({'status':{'type':'string','enum':['open','closed','archived']}})
schemas['SpaceAction']=obj({'action':{'type':'string','enum':['approve','invite','remove','ban','unban','admin','moderator','member']}})
schemas['SpaceInvite']=obj({'username':{**text(40),'minLength':1}})
schemas['NewSpaceEntry']=obj({'body':{**text(2000),'minLength':1}})
schemas['SpaceEntryCreated']=obj({'entryId':uuid_t})
schemas['SpaceEntryDeleted']=obj({'deleted':{'type':'boolean'}})
spid={'name':'spaceId','in':'path','required':True,'schema':uuid_t}
eid={'name':'entryId','in':'path','required':True,'schema':uuid_t}
operation('/v1/spaces','get','SharedSpacePage','Spaces','Browse communities, Moments or events hosted by members of your own age band (others behave as blocked); private spaces preview metadata only',parameters=[{'name':'kind','in':'query','schema':{'type':'string','enum':['community','moment','event'],'default':'community'}},{'name':'parentId','in':'query','schema':uuid_t},{'name':'mine','in':'query','schema':{'type':'boolean','default':False}}]+page_params)
operation('/v1/spaces','post','SharedSpace','Spaces','Create a shared space; scheduled spaces retain UTC plus an IANA host zone. Event and moment kinds answer 403 FEATURE_DISABLED unless SPACES_EVENTS_ENABLED is set (off for V1)','NewSpace')
operation('/v1/spaces/{spaceId}','get','SharedSpace','Spaces','Read authorized space metadata; invite-only spaces and blocked hosts return 404',parameters=[spid])
operation('/v1/spaces/{spaceId}','put','SharedSpace','Spaces','Host edits details, capacity and schedule; audience, kind and ancestry are immutable','NewSpace',parameters=[spid])
operation('/v1/spaces/{spaceId}/membership','put','SharedSpace','Spaces','Join, request approval or accept an invitation; serializes capacity checks','SpaceMembership',parameters=[spid])
operation('/v1/spaces/{spaceId}/membership','delete','SharedSpace','Spaces','Leave or withdraw your request; owners must retain their membership',parameters=[spid])
operation('/v1/spaces/{spaceId}/status','put','SharedSpace','Spaces','Host closes, archives or reopens a space; expired Moments remain read-only','SpaceStatus',parameters=[spid])
operation('/v1/spaces/{spaceId}/invitations','post','SharedSpace','Spaces','Invite a member by exact username; hosts only. Usernames are public, so the answer is the same (the space, or the same refusal) whether the name belongs to a member you may invite or to someone in the other age band, blocked from you or the owner, not onboarded, or nobody; only a member you may invite is invited and notified','SpaceInvite',parameters=[spid])
operation('/v1/spaces/{spaceId}/members','get','SpaceMemberPage','Spaces','Member-only participant list; moderation states require moderator role',parameters=[spid,{'name':'state','in':'query','schema':{'type':'string','enum':['active','pending','invited','banned'],'default':'active'}}]+page_params)
operation('/v1/spaces/{spaceId}/members/{userId}','put','SharedSpace','Spaces','Host or moderator approves, removes or bans; hierarchical roles protect owners and admins. Removing needs a membership row and banning a row or a member you may reach (active, onboarded, not barred from you or the owner); otherwise 404. Only a real change notifies the member','SpaceAction',parameters=[spid,uid])
operation('/v1/spaces/{spaceId}/entries','get','SpaceEntryPage','Spaces','Member-only shared discussion, with blocks and membership checked on every page',parameters=[spid]+page_params)
operation('/v1/spaces/{spaceId}/entries','post','SpaceEntryCreated','Spaces','Create a server-readable discussion entry; active membership and an open schedule required','NewSpaceEntry',parameters=[spid])
operation('/v1/spaces/{spaceId}/entries/{entryId}','delete','SpaceEntryDeleted','Spaces','Author or moderator removes a discussion entry',parameters=[spid,eid])
for endpoint in ['/v1/spaces','/v1/spaces/{spaceId}/entries']:
    paths[endpoint]['post']['responses']['201']=paths[endpoint]['post']['responses'].pop('200')
# Idempotency (docs/api/16-pulse-and-media.md): creating a post, a story or a space entry takes an optional Idempotency-Key.
idem = {'name':'Idempotency-Key','in':'header','required':False,'description':'A UUID the client makes once per create and sends unchanged on every retry. A retry returns the original 201 and body with Idempotent-Replayed: true and creates nothing. The same key with a different body, kind of item or space is 422 IDEMPOTENCY_KEY_REUSED. Keys are kept for 24 hours.','schema':{'type':'string','format':'uuid'}}
for endpoint in ['/v1/posts','/v1/stories','/v1/spaces/{spaceId}/entries']:
    created = paths[endpoint]['post']
    created.setdefault('parameters',[]).append(idem)
    created['responses']['201'].setdefault('headers',{})['Idempotent-Replayed'] = {'description':'true when this answer repeats an earlier request with the same Idempotency-Key.','schema':{'type':'string','enum':['true']}}
    created['responses']['422']['description'] += ' IDEMPOTENCY_KEY_REUSED: the Idempotency-Key was used for a different request; VALIDATION also covers an Idempotency-Key that is not a UUID.'
# Account deletion and data export (docs/api/22-account-deletion-and-export.md).
schemas['DeletionRequest']=obj({'confirmUsername':{**text(31),'description':'The member\'s own username, typed to confirm; compared without case and without a leading @.'},'appleAuthorizationCode':{**text(2048),'description':'Members who sign in with Apple only: the one-time authorization code from signing in with Apple again during deletion. The server exchanges it for a refresh token and revokes it at Apple (App Store guideline 5.1.1(v)) before the deletion is scheduled; 503 APPLE_REVOKE_FAILED when Apple cannot be reached or the code is stale, in which case nothing changed and the member signs in with Apple again to retry. Ignored with a warning when Apple revocation is not configured on the server.'}},['confirmUsername'])
schemas['DeletionState']=obj({'pending':{'type':'boolean','description':'True while the account is scheduled for deletion.'},'scheduledAt':{'type':['string','null'],'format':'date-time'},'dueAt':{'type':['string','null'],'format':'date-time','description':'End of the 30 day grace period; the account is purged on the first hourly run after it.'},'canCancel':{'type':'boolean','description':'True while pending and before dueAt.'}})
operation('/v1/me/deletion','get','DeletionState','Account','Whether deletion is scheduled and until when. The only route besides cancel and sign-out that a member in the grace period can reach; allowed before onboarding')
operation('/v1/me/deletion','post','DeletionState','Account','Schedule deletion of your account in 30 days. Needs a sign-in from the last 5 minutes (Firebase auth_time) and your username as confirmation. At once: the account leaves Discover, Nearby, search, lists, Pulse and everyone\'s counts; every session is revoked and live sockets are closed; push tokens are cleared. Idempotent while pending. Allowed before onboarding','DeletionRequest',errors={
    '403':'Error 403 REAUTH_REQUIRED: the sign-in is older than 5 minutes (development authentication is exempt); sign in again and retry. ONBOARDING_REQUIRED does not apply.',
    '422':'Error 422 VALIDATION: confirmUsername is missing, extra keys were sent, or it is not your username.',
    '503':'Error 503 APPLE_REVOKE_FAILED: appleAuthorizationCode was sent but Apple could not be told (unreachable, or the code is stale). Nothing changed; sign in with Apple again and retry.',
    '429':'Error 429 RATE_LIMITED: the per-account graph limit; retry after the Retry-After header.'})
operation('/v1/me/deletion','delete','DeletionState','Account','Cancel a scheduled deletion during the grace period (sign in again first: sessions were revoked). The account is exactly as it was, with its content',errors={
    '404':'Error 404 NOT_FOUND: no deletion is scheduled.',
    '409':'Error 409 DELETION_WINDOW_CLOSED: the 30 days have passed; the purge may already be running.'})
schemas['ExportDocument']={'type':'object','additionalProperties':True,'description':'The member\'s data: exportVersion, generatedAt, note, account, settings, interests, posts, comments, reactions, saves, stories, connections {following, followers, friends}, blocks, mutes, restrictions, sessions, devices, notifications, visits {made, ownProfileVisitors}, location {sharing, updatedAt}, spaces {memberships, owned, entries}, reports (own words only), media (links valid 24 hours), chat (conversation ids, peers and counts; message content is end-to-end encrypted and not included), truncated (names of lists cut at 10,000 rows or 32 MiB), complete.'}
paths['/v1/me/export']={'get':{'operationId':'getExportDocument_v1_me_export','tags':['Account'],'summary':'Download your data as one JSON file (Content-Disposition: attachment), streamed from a single snapshot. Not wrapped in the usual success envelope. One export per account per 24 hours, enforced by the server; a failed export does not use the slot. The date of birth is never included (the age band is), nor coordinates, tokens or report evidence','security':[{'bearerAuth':[]}],'responses':{
    '200':{'description':'The document','headers':{'Content-Disposition':{'schema':{'type':'string'},'description':'attachment; filename="hiyall-data-YYYY-MM-DD.json"'}},'content':{'application/json':{'schema':ref('ExportDocument')}}},
    '401':{'description':'Error 401 UNAUTHENTICATED (also for an account scheduled for deletion).','content':{'application/json':{'schema':ref('ErrorResponse')}}},
    '403':{'description':'Error 403 ONBOARDING_REQUIRED.','content':{'application/json':{'schema':ref('ErrorResponse')}}},
    '429':{'description':'Error 429 RATE_LIMITED: already exported in the last 24 hours; Retry-After is the seconds until the next one.','content':{'application/json':{'schema':ref('ErrorResponse')}}}}}}
spec = {'openapi':'3.1.1','info':{'title':'Hiyall foundation API','version':'0.1.0','description':'Implemented local foundation. The MVP contract is a separate roadmap. Profile/privacy and shared discussions are server-readable; direct chat relays ciphertext only. Not modelled as a path because OpenAPI does not describe WebSocket upgrades: GET /v1/realtime (bearer token, onboarding required) upgrades to a socket of content-free wake-up events (ready, inbox, activity, read, typing, device, resync; device means a chat device was added to or removed from your account; the client may send {"type":"typing","conversationId"}). It lives only as long as its session: logout, revoke, sign out everywhere else, suspension and expiry (checked every 25 seconds) close it with 1008 "session ended", and 1013 asks the client to resync and reconnect. Refusals are the JSON error envelope with the request id: 401, 403 ONBOARDING_REQUIRED, 429 RATE_LIMITED, 503 AT_CAPACITY (10 sockets per account). When the server enforces Firebase App Check, every authenticated request (the socket included) also carries the X-Firebase-AppCheck header.','license':{'name':'Private project','identifier':'LicenseRef-Proprietary'}},'servers':[{'url':'http://127.0.0.1:8080','description':'Local development only; production must terminate HTTPS'}],'tags':[{'name':name,'description':description} for name,description in [('Health','Service probes'),('Development','Explicit local development fixtures'),('Profile','Profile, privacy and blocks'),('Onboarding','Self-declared minimum age (13), terms and username before the app opens'),('Sessions','Account access and revocation'),('Discovery','People search over discoverable public profiles'),('Graph','Follows, friend requests and connection lists'),('Activity','Recipient-only notifications'),('Nearby','Opt-in, coarse, expiring location; people nearby as distance buckets'),('Chat','End-to-end encrypted direct chat relay (Olm via vodozemac); ciphertext only'),('Safety','Mute, restrict, chat mute, control lists and reports; never visible to the person they are about'),('Pulse','Photos, posts, feed, reactions, comments, saves and stories'),('Spaces','Communities, bounded Moments and events, visible within a member\'s own age band')]],'paths':paths,'components':{'securitySchemes':{'bearerAuth':{'type':'http','scheme':'bearer','bearerFormat':'JWT','description':'Production sign-in is a Firebase Authentication ID token sent on every request (when FIREBASE_PROJECT_ID is set); generic OIDC deployments take a verified OIDC access JWT and reject ID tokens. Local development uses an opaque /dev/session token. A password sign-in needs a verified email (403 EMAIL_NOT_VERIFIED). See docs/api/18-accounts-and-onboarding.md.'}},'schemas':schemas}}
(root / 'docs/api/openapi-foundation.json').write_text(json.dumps(spec,indent=2)+'\n')
