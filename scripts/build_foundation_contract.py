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
for field in ['profileAccent', 'profilePattern', 'avatarFrame']:
    schemas['ProfilePatch']['properties'][field]['enum'].remove('')
for name in ['PrivacySettings', 'PrivacyPatch']:
    audience_fields = schemas[name]['properties']['fieldAudiences']
    audience_fields['properties']['connections'] = {'type': 'string', 'enum': ['everyone', 'friends', 'followers', 'nobody']}
    audience_fields['properties']['vibe'] = {'type': 'string', 'enum': ['everyone', 'friends', 'followers', 'nobody']}
    if name == 'PrivacySettings':
        audience_fields['required'].extend(['vibe', 'connections'])
        audience_fields['minProperties'] = len(audience_fields['required'])
for field in ['verified', 'following', 'friendship', 'reasonCodes', 'sharedInterestCount', 'city', 'region']:
    schemas['PublicProfile']['properties'].pop(field, None)
    if field in schemas['PublicProfile']['required']: schemas['PublicProfile']['required'].remove(field)
for field in ['avatarMediaId', 'coverMediaId']:
    schemas['ProfilePatch']['properties'][field] = {'type': 'null', 'description': 'Uploads are not implemented; clearing a reference is allowed.'}
def obj(properties, required=None):
    return {'type': 'object', 'additionalProperties': False, 'properties': properties, 'required': list(properties) if required is None else required}
def text(maximum=256):
    return {'type': 'string', 'maxLength': maximum}
def ref(name):
    return {'$ref': f'#/components/schemas/{name}'}
schemas['SocialStats'] = obj({key: {'type': 'integer', 'minimum': 0, 'readOnly': True} for key in ['friends', 'following', 'followers']})
for name in ['SelfProfile', 'PublicProfile']:
    schemas[name]['properties']['socialStats'] = {**ref('SocialStats'), 'description': 'Counts of active persisted relationships, excluding inactive and blocked accounts. Omitted from visitor profiles unless allowed.'}
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
    'cursor': {'type': 'string', 'maxLength': 2048},
}, [])
schemas['DiscoveryPerson'] = obj({
    key: copy.deepcopy(schemas['PublicProfile']['properties'][key])
    for key in ['userId', 'username', 'displayName', 'headline', 'bio', 'interests', 'languages', 'currentVibe', 'country']
}, ['userId', 'username', 'displayName', 'headline', 'bio'])
schemas['PeoplePage'] = obj({'items': {'type': 'array', 'maxItems': 20, 'items': ref('DiscoveryPerson')}, 'nextCursor': {'type': ['string', 'null'], 'maxLength': 2048}})
schemas['DevelopmentLogin'] = obj({'userId':{'type':'string','enum':['019a4000-0000-7000-8000-000000000001','019a4000-0000-7000-8000-000000000002']}})
schemas['DevelopmentSession'] = obj({'accessToken':{'type':'string','minLength':43,'maxLength':43},'userId':{'type':'string','format':'uuid'},'sessionId':{'type':'string','format':'uuid'},'expiresIn':{'type':'integer','minimum':1800,'maximum':1800}})
uuid_t = {'type':'string','format':'uuid'}
when = {'type':'string','format':'date-time'}
schemas['UserSummary'] = obj({'userId':uuid_t,'username':{'type':'string','pattern':'^[a-z0-9_]{3,30}$'},'displayName':text(80)})
schemas['Relationship'] = obj({
    'following': {'type':'string','enum':['none','pending','active'],'description':'Viewer follows the profile owner.'},
    'followedBy': {'type':'boolean'},
    'friendship': {'type':'string','enum':['none','pending_outgoing','pending_incoming','accepted']},
    'friendRequestId': {**uuid_t,'description':'Present while a request is pending, so the client can accept or cancel it.'},
    'canFollow': {'type':'boolean'},
    'canFriendRequest': {'type':'boolean'},
}, ['following','followedBy','friendship','canFollow','canFriendRequest'])
schemas['PublicProfile']['properties']['relationship'] = ref('Relationship')
schemas['PublicProfile']['properties']['locked'] = {'type':'boolean','description':'True when the profile audience excludes the viewer. A locked card carries only identity, style and relationship.'}
for field in list(schemas['PublicProfile']['required']):
    if field not in ['userId','username','displayName']:
        schemas['PublicProfile']['required'].remove(field)
schemas['FollowState'] = obj({'following':{'type':'string','enum':['none','pending','active']}})
schemas['FollowerState'] = obj({'follower':{'const':'active'}})
schemas['FriendshipState'] = obj({'friendship':{'const':'none'}})
schemas['Removed'] = obj({'removed':{'type':'boolean'}})
schemas['Cancelled'] = obj({'cancelled':{'type':'boolean'}})
schemas['Read'] = obj({'read':{'type':'boolean'}})
schemas['ReadAll'] = obj({'updated':{'type':'integer','minimum':0}})
schemas['UnreadCount'] = obj({'unreadCount':{'type':'integer','minimum':0}})
schemas['Connection'] = obj({'user':ref('UserSummary'),'since':when})
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
for name in ['Connection','FriendRequest','Notification']:
    props = {'items':{'type':'array','maxItems':50,'items':ref(name)}, **page_meta}
    if name == 'Notification':
        props['unreadCount'] = {'type':'integer','minimum':0}
    schemas[name+'Page'] = obj(props)
b64key = {'type':'string','pattern':'^[A-Za-z0-9+/]{43}$','description':'Unpadded base64 32-byte public key'}
b64sig = {'type':'string','pattern':'^[A-Za-z0-9+/]{86}$','description':'Unpadded base64 Ed25519 signature'}
schemas['DeviceRegister'] = obj({'deviceId':uuid_t,'identityKey':b64key,'signingKey':b64key,'signature':{**b64sig,'description':'Ed25519 over "kairova-device-v1\\n{userId}\\n{deviceId}\\n{identityKey}\\n{signingKey}"'},'platform':{'type':'string','enum':['android','ios','web','linux','unknown']},'displayName':text(60)},['deviceId','identityKey','signingKey','signature'])
schemas['Device'] = obj({'deviceId':uuid_t,'userId':uuid_t,'identityKey':b64key,'signingKey':b64key,'signature':b64sig,'platform':{'type':'string'},'displayName':text(60),'createdAt':when})
schemas['DeviceList'] = obj({'items':{'type':'array','maxItems':10,'items':ref('Device')}})
schemas['SignedKey'] = obj({'keyId':text(64),'publicKey':b64key,'signature':{**b64sig,'description':'Ed25519 over "kairova-otk-v1\\n{userId}\\n{deviceId}\\n{keyId}\\n{publicKey}"'}})
schemas['KeyUpload'] = obj({'oneTimeKeys':{'type':'array','maxItems':50,'items':ref('SignedKey')},'fallbackKey':ref('SignedKey')},[])
schemas['KeyCount'] = obj({'oneTimeKeyCount':{'type':'integer','minimum':0,'maximum':100},'hasFallbackKey':{'type':'boolean'}},['oneTimeKeyCount'])
schemas['ClaimedKey'] = obj({'deviceId':uuid_t,'keyId':text(64),'publicKey':b64key,'signature':b64sig,'fallback':{'type':'boolean'}})
schemas['ConversationOpen'] = obj({'userId':uuid_t})
schemas['DirectConversation'] = obj({'conversationId':uuid_t,'peer':ref('UserSummary'),'status':{'type':'string','enum':['active','closed']},'createdAt':when,'lastMessageAt':{'type':['string','null'],'format':'date-time'}})
schemas['DirectConversationPage'] = obj({'items':{'type':'array','maxItems':50,'items':ref('DirectConversation')}, **page_meta})
schemas['CiphertextEnvelope'] = obj({'deviceId':uuid_t,'type':{'type':'integer','enum':[0,1],'description':'0 = Olm pre-key message, 1 = Olm message'},'ciphertext':{'type':'string','maxLength':21848,'pattern':'^[A-Za-z0-9+/]+$','description':'Unpadded base64 Olm ciphertext, at most 16 KiB decoded'}})
schemas['EncryptedMessageSend'] = obj({'messageId':uuid_t,'senderDeviceId':uuid_t,'envelopes':{'type':'array','minItems':1,'maxItems':20,'items':ref('CiphertextEnvelope'),'description':'Exactly one per active device of the peer and of the sender other than senderDeviceId; otherwise 409 DEVICES_CHANGED'}})
schemas['MessageAccepted'] = obj({'messageId':uuid_t,'createdAt':when})
schemas['InboxItem'] = obj({'messageId':uuid_t,'conversationId':uuid_t,'senderId':uuid_t,'senderDeviceId':uuid_t,'senderIdentityKey':b64key,'type':{'type':'integer','enum':[0,1]},'ciphertext':{'type':'string'},'createdAt':when})
schemas['Inbox'] = obj({'items':{'type':'array','maxItems':100,'items':ref('InboxItem')}})
schemas['InboxAck'] = obj({'messageIds':{'type':'array','minItems':1,'maxItems':100,'items':uuid_t}})
schemas['Acknowledged'] = obj({'acknowledged':{'type':'integer','minimum':0}})
paths = {}
def operation(path, method, response, tag, summary, body=None, parameters=None, public=False):
    wrapper = response+'Response'
    schemas[wrapper] = obj({'success':{'const':True},'data':ref(response),'meta':ref('Meta')})
    responses = {'200':{'description':'Successful operation','content':{'application/json':{'schema':ref(wrapper)}}}}
    for status in ['401','403','404','409','412','422','428','429','500','503']:
        responses[status] = {'description':f'Error {status}; no internal details disclosed','content':{'application/json':{'schema':ref('ErrorResponse')}}}
    op = {'operationId':method+response+path.replace('/','_').replace('{','').replace('}',''), 'tags':[tag], 'summary':summary,'security':[] if public else [{'bearerAuth':[]}], 'responses':responses}
    if parameters: op['parameters'] = parameters
    if body: op['requestBody'] = {'required':True,'content':{'application/json':{'schema':ref(body)}}}
    paths.setdefault(path,{})[method] = op
match = {'name':'If-Match','in':'header','required':True,'description':'Quoted positive resource version, for example "1".','schema':{'type':'string','maxLength':21,'pattern':'^"[1-9][0-9]{0,18}"$'}}
uid = {'name':'userId','in':'path','required':True,'schema':{'type':'string','format':'uuid'}}
sid = {'name':'sessionId','in':'path','required':True,'schema':{'type':'string','format':'uuid'}}
for path in ['/health/live','/health/ready']: operation(path,'get','Health','Health','Check service health',public=True)
operation('/dev/session','post','DevelopmentSession','Development','Local-only development session; absent in production','DevelopmentLogin',public=True)
for path,response,patch in [('/v1/me/profile','SelfProfile','ProfilePatch'),('/v1/me/privacy','PrivacySettings','PrivacyPatch')]:
    operation(path,'get',response,'Profile','Read your current settings')
    operation(path,'patch',response,'Profile','Update your settings atomically',patch,[match])
operation('/v1/users/{userId}/profile','get','PublicProfile','Profile','Read a profile with your relationship; audiences that exclude you return a locked card; blocked and inactive accounts return 404',parameters=[uid])
for method in ['post','delete']: operation('/v1/users/{userId}/block',method,'Blocked','Profile','Change a block; both viewing directions are denied while blocked',parameters=[uid])
operation('/v1/discovery/search', 'post', 'PeoplePage', 'Discovery', 'Search opted-in public adult-eligible profiles; public fields only, OR within a collection and AND across dimensions; 20 per page, at most 10 pages, principal/query-bound cursors', 'PeopleSearch')
operation('/v1/auth/logout','post','Revoked','Sessions','Revoke the current session')
operation('/v1/auth/sessions','get','SessionPage','Sessions','List only your sessions with a principal-bound cursor',parameters=[{'name':'limit','in':'query','schema':{'type':'integer','minimum':1,'maximum':50,'default':20}},{'name':'cursor','in':'query','schema':text(2048)}])
operation('/v1/auth/sessions/{sessionId}','delete','Revoked','Sessions','Revoke an owned session; foreign sessions return 404',parameters=[sid])
page_params = [{'name':'limit','in':'query','schema':{'type':'integer','minimum':1,'maximum':50,'default':20}},{'name':'cursor','in':'query','schema':text(2048),'description':'Opaque, principal- and list-bound, expires after 15 minutes.'}]
rid = {'name':'requestId','in':'path','required':True,'schema':uuid_t}
nid = {'name':'notificationId','in':'path','required':True,'schema':uuid_t}
operation('/v1/users/{userId}/follow','post','FollowState','Graph','Follow; approval policies yield pending, "nobody" returns 403 FOLLOW_NOT_ALLOWED; idempotent',parameters=[uid])
operation('/v1/users/{userId}/follow','delete','FollowState','Graph','Unfollow or withdraw a pending request; idempotent',parameters=[uid])
operation('/v1/users/{userId}/follow-requests/accept','post','FollowerState','Graph','Approve a pending follower; only the profile owner can',parameters=[uid])
operation('/v1/me/follow-requests','get','ConnectionPage','Graph','Pending followers awaiting your approval',parameters=page_params)
operation('/v1/me/follow-requests/{userId}','delete','Removed','Graph','Decline a pending follower',parameters=[uid])
operation('/v1/me/followers/{userId}','delete','Removed','Graph','Remove an active follower without blocking',parameters=[uid])
operation('/v1/users/{userId}/friend-requests','post','FriendRequest','Graph','Send a friend request under the target requestsFrom policy; crossing requests accept; 7-day cooldown after a decline (429 REQUEST_COOLDOWN)',parameters=[uid])
operation('/v1/me/friend-requests','get','FriendRequestPage','Graph','Pending friend requests',parameters=[{'name':'direction','in':'query','schema':{'type':'string','enum':['incoming','outgoing'],'default':'incoming'}}]+page_params)
for action in ['accept','decline']:
    operation('/v1/friend-requests/{requestId}/'+action,'post','FriendRequest','Graph',action.capitalize()+' a request addressed to you; anyone else gets 404',parameters=[rid])
operation('/v1/friend-requests/{requestId}','delete','Cancelled','Graph','Cancel your own pending request',parameters=[rid])
operation('/v1/users/{userId}/friendship','delete','FriendshipState','Graph','Unfriend; idempotent',parameters=[uid])
for kind in ['friends','followers','following']:
    operation('/v1/me/'+kind,'get','ConnectionPage','Graph','Your '+kind,parameters=page_params)
    operation('/v1/users/{userId}/'+kind,'get','ConnectionPage','Graph','Another person\'s '+kind+'; needs profile and connections audience access (403 CONNECTIONS_PRIVATE); blocked and inactive accounts are omitted',parameters=[uid]+page_params)
operation('/v1/notifications','get','NotificationPage','Activity','Your activity, newest first; actors you are blocked with or who are inactive are hidden',parameters=[{'name':'unreadOnly','in':'query','schema':{'type':'boolean'}}]+page_params)
operation('/v1/notifications/unread-count','get','UnreadCount','Activity','Unread activity count')
operation('/v1/notifications/read-all','post','ReadAll','Activity','Mark all activity read')
operation('/v1/notifications/{notificationId}/read','post','Read','Activity','Mark one of your notifications read; idempotent',parameters=[nid])
did = {'name':'deviceId','in':'path','required':True,'schema':uuid_t}
cid = {'name':'conversationId','in':'path','required':True,'schema':uuid_t}
operation('/v1/devices','post','Device','Chat','Register this device\'s public identity; idempotent; 409 DEVICE_CONFLICT or TOO_MANY_DEVICES','DeviceRegister')
operation('/v1/me/devices','get','DeviceList','Chat','Your active devices')
operation('/v1/devices/{deviceId}','delete','Revoked','Chat','Revoke your device; drops its keys and undelivered ciphertext',parameters=[did])
operation('/v1/devices/{deviceId}/keys','post','KeyCount','Chat','Upload signed one-time keys (at most 100 held) and a fallback key','KeyUpload',parameters=[did])
operation('/v1/devices/{deviceId}/keys','get','KeyCount','Chat','Unclaimed key count for your device',parameters=[did])
operation('/v1/users/{userId}/devices','get','DeviceList','Chat','Another person\'s devices, only if their messagesFrom allows you (403 MESSAGES_NOT_ALLOWED)',parameters=[uid])
operation('/v1/users/{userId}/devices/{deviceId}/claim','post','ClaimedKey','Chat','Claim a one-time key exactly once; falls back to the fallback key',parameters=[uid,did])
operation('/v1/conversations','post','DirectConversation','Chat','Open or reopen the direct conversation with a person','ConversationOpen')
operation('/v1/conversations','get','DirectConversationPage','Chat','Your active conversations, most recent first',parameters=page_params)
operation('/v1/conversations/{conversationId}','get','DirectConversation','Chat','One of your conversations',parameters=[cid])
operation('/v1/conversations/{conversationId}/messages','post','MessageAccepted','Chat','Relay one ciphertext per recipient device; the server never receives plaintext; idempotent by messageId','EncryptedMessageSend',parameters=[cid])
operation('/v1/devices/{deviceId}/inbox','get','Inbox','Chat','Undelivered ciphertext for your device, oldest first',parameters=[did,{'name':'limit','in':'query','schema':{'type':'integer','minimum':1,'maximum':100,'default':50}}])
operation('/v1/devices/{deviceId}/inbox/ack','post','Acknowledged','Chat','Mark delivered; the server deletes the ciphertext','InboxAck',parameters=[did])
# Phase 6: adult-only shared spaces (server-readable discussions).
space_input = {'kind':{'type':'string','enum':['community','moment','event']},'title':{**text(80),'minLength':1},'description':text(2000),'rules':text(2000),'visibility':{'type':'string','enum':['public','private','invite']},'parentId':{'type':['string','null'],'format':'uuid'},'capacity':{'type':'integer','minimum':2,'maximum':10000},'startsAt':{'type':['string','null'],'format':'date-time'},'endsAt':{'type':['string','null'],'format':'date-time'},'timezone':text(100),'location':text(240)}
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
operation('/v1/spaces','get','SharedSpacePage','Spaces','Browse adult-only communities, Moments or events; private spaces preview metadata only',parameters=[{'name':'kind','in':'query','schema':{'type':'string','enum':['community','moment','event'],'default':'community'}},{'name':'parentId','in':'query','schema':uuid_t},{'name':'mine','in':'query','schema':{'type':'boolean','default':False}}]+page_params)
operation('/v1/spaces','post','SharedSpace','Spaces','Create a shared space; scheduled spaces retain UTC plus an IANA host zone','NewSpace')
operation('/v1/spaces/{spaceId}','get','SharedSpace','Spaces','Read authorized space metadata; invite-only spaces and blocked hosts return 404',parameters=[spid])
operation('/v1/spaces/{spaceId}','put','SharedSpace','Spaces','Host edits details, capacity and schedule; audience, kind and ancestry are immutable','NewSpace',parameters=[spid])
operation('/v1/spaces/{spaceId}/membership','put','SharedSpace','Spaces','Join, request approval or accept an invitation; serializes capacity checks','SpaceMembership',parameters=[spid])
operation('/v1/spaces/{spaceId}/membership','delete','SharedSpace','Spaces','Leave or withdraw your request; owners must retain their membership',parameters=[spid])
operation('/v1/spaces/{spaceId}/status','put','SharedSpace','Spaces','Host closes, archives or reopens a space; expired Moments remain read-only','SpaceStatus',parameters=[spid])
operation('/v1/spaces/{spaceId}/invitations','post','SharedSpace','Spaces','Invite an eligible adult by exact username; hosts only','SpaceInvite',parameters=[spid])
operation('/v1/spaces/{spaceId}/members','get','SpaceMemberPage','Spaces','Member-only participant list; moderation states require moderator role',parameters=[spid,{'name':'state','in':'query','schema':{'type':'string','enum':['active','pending','invited','banned'],'default':'active'}}]+page_params)
operation('/v1/spaces/{spaceId}/members/{userId}','put','SharedSpace','Spaces','Host or moderator approves, removes or bans; hierarchical roles protect owners and admins','SpaceAction',parameters=[spid,uid])
operation('/v1/spaces/{spaceId}/entries','get','SpaceEntryPage','Spaces','Member-only shared discussion, with blocks and age eligibility checked on every page',parameters=[spid]+page_params)
operation('/v1/spaces/{spaceId}/entries','post','SpaceEntryCreated','Spaces','Create a server-readable discussion entry; active membership and an open schedule required','NewSpaceEntry',parameters=[spid])
operation('/v1/spaces/{spaceId}/entries/{entryId}','delete','SpaceEntryDeleted','Spaces','Author or moderator removes a discussion entry',parameters=[spid,eid])
for endpoint in ['/v1/spaces','/v1/spaces/{spaceId}/entries']:
    paths[endpoint]['post']['responses']['201']=paths[endpoint]['post']['responses'].pop('200')
spec = {'openapi':'3.1.1','info':{'title':'Kairova foundation API','version':'0.1.0','description':'Implemented local foundation. The MVP contract is a separate roadmap. Profile/privacy and shared discussions are server-readable; direct chat relays ciphertext only.','license':{'name':'Private project','identifier':'LicenseRef-Proprietary'}},'servers':[{'url':'http://127.0.0.1:8080','description':'Local development only; production must terminate HTTPS'}],'tags':[{'name':name,'description':description} for name,description in [('Health','Service probes'),('Development','Explicit local development fixtures'),('Profile','Profile, privacy and blocks'),('Sessions','Account access and revocation'),('Discovery','Adult-eligible public people search'),('Graph','Follows, friend requests and connection lists'),('Activity','Recipient-only notifications'),('Chat','End-to-end encrypted direct chat relay (Olm via vodozemac); ciphertext only'),('Spaces','Adult-only communities, bounded Moments and events')]],'paths':paths,'components':{'securitySchemes':{'bearerAuth':{'type':'http','scheme':'bearer','description':'Opaque local token or verified OIDC access JWT; ID tokens are rejected.'}},'schemas':schemas}}
(root / 'docs/api/openapi-foundation.json').write_text(json.dumps(spec,indent=2)+'\n')
