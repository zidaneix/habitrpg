_ = require('lodash')
{helpers} = require('habitrpg-shared')
u = require './user.coffee'

module.exports.app = (app, model) ->
  browser = require './browser.coffee'

  currentTime = model.at '_page.currentTime'
  currentTime.setNull +new Date
  # Every 60 seconds, reset the current time so that the chat can update relative times
  setInterval (->currentTime.set +new Date), 60000

  user = u.userAts(model)

  app.fn 'groupCreate', (e,el) ->
    type = $(el).attr('data-type')
    newGroup =
      name: model.get("_page.new.group.name")
      description: model.get("_page.new.group.description")
      leader: user.id
      members: [user.id]
      type: type
      ids: {challenges: []}
      challenges: {}

    # parties - free
    if type is 'party'
      return model.add 'groups', newGroup, ->location.reload()

    # guilds - 4G
    unless user.priv.get('balance') >= 1
      return $('#more-gems-modal').modal 'show'
    if confirm "Create Guild for 4 Gems?"
      newGroup.privacy = (model.get("_page.new.group.privacy") || 'public') if type is 'guild'
      newGroup.balance = 1 # they spent $ to open the guild, it goes into their guild bank
      model.add 'groups', newGroup, ->
        user.priv.increment 'balance', -1, ->location.reload()

  app.fn 'toggleGroupEdit', (e, el) ->
    path = "_page.editing.groups.#{$(el).attr('data-gid')}"
    model.set path, !model.get(path)

  app.fn 'toggleLeaderMessageEdit', (e, el) ->
    path = "_page.editing.leaderMessage.#{$(el).attr('data-gid')}"
    model.set path, !model.get(path)

  app.fn 'groupAddWebsite', (e, el) ->
    e.at().unshift 'websites', model.get('_page.new.groupWebsite'), ->
      model.del '_page.new.groupWebsite'

  app.fn 'groupInvite', (e,el) ->
    uid = model.get('_page.new.groupInvite').replace(/[\s"]/g, '')
    model.set '_page.new.groupInvite', ''
    return if _.isEmpty(uid)

    $user = model.at "usersPublic.#{uid}"
    $user.fetch (err) ->
      throw err if err
      profile = $user.get()
      return model.set("_page.errors.group", "User with id #{uid} not found.") unless profile

      $groups = model.query 'groups', {members: $in: [uid]}
      $groups.fetch (err) ->
        throw err if err
        [group, groups] = [e.get(), $groups.get()]
        {type, name} = group; gid = group.id
        groupError = (msg) -> model.set("_page.errors.group", msg)
        invite = ->
          $.bootstrapGrowl "Invitation Sent."
          switch type
            when 'guild' then $user.push "invitations.guilds", {id:gid, name}, ->location.reload()
            when 'party' then $user.set "invitations.party", {id:gid, name}, ->location.reload()

        switch type
          when 'guild'
            if profile.invitations?.guilds and _.find(profile.invitations.guilds, {id:gid})
              return groupError("User already invited to that group")
            else if uid in group.members
              return groupError("User already in that group")
            else invite()
          when 'party'
            if profile.invitations?.party
              return groupError("User already pending invitation.")
            else if _.find(groups, {type:'party'})
              return groupError("User already in a party.")
            else invite()

  joinGroup = (gid) ->
    $group = model.at "groups.#{gid}"
    $group.fetch (err) -> $group.push("members", user.id, ->location.reload())

  app.fn 'joinGroup', (e, el) -> joinGroup e.get('id')

  app.fn 'acceptInvitation', (e,el) ->
    gid = e.get('id')
    if $(el).attr('data-type') is 'party'
      user.pub.set 'invitations.party', null, ->joinGroup(gid)
    else
      e.at().remove ->joinGroup(gid)

  app.fn 'rejectInvitation', (e, el) ->
    clear = -> browser.resetDom(model)
    if e.at().path().indexOf('party') != -1
      model.del e.at().path(), clear
    else e.at().remove clear

  app.fn 'groupLeave', (e,el) ->
    if confirm("Leave this group, are you sure?") is true
      uid = user.id
      group = model.at "groups.#{$(el).attr('data-id')}"
      index = group.get('members').indexOf(uid)
      if index != -1
        group.remove 'members', index, 1, ->
          updated = group.get()
          # last member out, delete the party
          if _.isEmpty(updated.members) and (updated.type is 'party')
            group.del ->location.reload()
          # assign new leader, so the party is editable #TODO allow old leader to assign new leader, this is just random
          else if (updated.leader is uid)
            group.set "leader", updated.members[0], ->location.reload()
          else location.reload()

  ###
    Chat Functionality
  ###

  model.on 'insert', '_page.party.chat', -> $('.chat-message').tooltip()
  model.on 'insert', '_page.tavern.chat', -> $('.chat-message').tooltip()

  app.fn 'sendChat', (e,el) ->
    text = model.get '_page.new.chat'
    # Check for non-whitespace characters
    return unless /\S/.test text

    group = e.at()

    # get rid of duplicate member ids - this is a weird place to put it, but works for now
    members = group.get('members'); uniqMembers = _.uniq(members)
    group.set('members', uniqMembers) if !_.isEqual(uniqMembers, members)

    model.set('_page.new.chat', '')

    id = model.id()
    message =
      id: id
      uuid: user.id
      contributor: user.pub.get('backer.contributor')
      npc: user.pub.get('backer.npc')
      text: text
      user: helpers.username(user.priv.get('auth'), user.pub.get('profile.name'))
      timestamp: +new Date

    group.unshift 'chat', message, ->group.remove('chat', 200)
    type = $(el).attr('data-type')
    user.priv.set 'party.lastMessageSeen', id if group.get('type') is 'party'

  app.fn 'chatKeyup', (e, el, next) ->
    return next() unless e.keyCode is 13
    app.sendChat(e, el)

  app.fn 'deleteChatMessage', (e) ->
    if confirm("Delete chat message?") is true
      e.at().remove() #requires the {#with}

  app.on 'render', (ctx) ->
    $('#party-tab-link').on 'shown', (e) ->
      messages = model.get('_page.party.chat')
      return false unless messages?.length > 0
      user.priv.set 'party.lastMessageSeen', messages[0].id

  app.fn 'gotoPartyChat', ->
    model.set '_page.active.gamePane', true, ->
      $('#party-tab-link').tab('show')

  app.fn 'assignGroupLeader', (e, el) ->
    newLeader = model.get('_page.new.groupLeader')
    if newLeader and (confirm("Assign new leader, you sure?") is true)
      e.at().set('leader', newLeader, ->browser.resetDom(model)) if newLeader