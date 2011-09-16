------------------------------------------------------------------------
-- Bamboo is a Lua web framework
--
-- Bamboo is BSD licensed the same as Mongrel2.
------------------------------------------------------------------------

package.path = package.path .. './?.lua;./?/init.lua;../?.lua;../?/init.lua;'
require 'lglib'

module('bamboo', package.seeall)

local Set = require 'lglib.set'


URLS = {}

------------------------------------------------------------------------
PLUGIN_LIST = {}

registerPlugin = function (name, mdl)
	checkType(name, mdl, 'string', 'table')
	assert( name ~= '', 'Plugin name must not be blank.' )
	assert( mdl.main, 'Plugin must have a main function.' )
	checkType( mdl.main, 'function' )
	
	PLUGIN_LIST[name] = mdl.main
	
	-- combine URLS in each module to the global URLS
	if mdl['URLS'] then
		table.update(URLS, mdl.URLS)
	end	
end
------------------------------------------------------------------------

MODULE_LIST = {}
-- 
registerModule = function (mdl, extra_params)
	checkType(mdl, 'table')
	
	if mdl.URLS then
		checkType(mdl.URLS, 'table')
		
		for url, action in pairs(mdl.URLS) do
			local propagated_params = {}

			local nurl = ''
			if (url == '/' or not url:startsWith('/')) and mdl._NAME then
				-- print(url)
				-- make the relative url pattern to absolute url pattern
				local module_name = mdl._NAME:match('%.([%w_]+)$')
				nurl = ('/%s/%s'):format(module_name, url)
				-- print(nurl)
			else
				nurl = url
			end
			
			local nfun
			local exclude_flag = false
			if extra_params then
				checkType(extra_params, 'table')
				if extra_params['excludes'] then
				-- add exceptions to module's init function
					for _, exclude in ipairs(extra_params['excludes']) do
						if exclude == url then
							exclude_flag = true
						end
					end
				end
			end
			
			local function permissionCheck(action_perms, perms)
				if #perms > 0 then
					local perm_list = {}
					for _, perm in ipairs(perms) do
						perm_list[#perm_list + 1] = perm.name
					end
					
					local perms_setA = Set(perm_list)
					local perms_setB = Set(action_perms)
					local flag, diff_elem = perms_setB:isSub(perms_setA)
					
					if flag then
						-- if action permissions are contained by given permissions
						-- execute success function
						-- TODO
						local ret = nil
						for _, perm_name in ipairs(action_perms) do
							local perm_do = getPermissionByName(perm_name)
							if not perm_do then
								print(('[Warning] This permission %s is not registered.'):format(perm_name))
							elseif perm_do and perm_do.success_func then
								ret = perm_do.success_func()
								-- once one permission success function return false
								-- jump out
								if not ret then
									print(('[Prompt] permission check chains was broken at %s'):format(perm_name))
									return false
								end
							end
						end
						
						return true
					else
						-- execute failure function
						local perm_not_fit = getPermissionByName(diff_elem)
						if perm_not_fit and perm_not_fit.failure_func then
							print(('[Prompt] enter failure function %s.'):format(diff_elem))
							perm_not_fit.failure_func()
						end

						return false
					end
				else
					print('[Prompt] No permissions in the given list.')
					local perm_not_fit = getPermissionByName(action_perms[1])
					if perm_not_fit and perm_not_fit.failure_func then
						print(('[Prompt] enter failure function %s.'):format(action_perms[1]))
						perm_not_fit.failure_func()
					end

					return false				
				end
			end
			
			
			local function actionTransform(web, req)
				if type(action) == 'function' then
					return action
				elseif type(action) == 'table' then
					local fun = action.handler
					checkType(fun, 'function')
					
					return function (web, req, propagated_params)
						local filter_flag, permission_flag = true, true
						
						-- check filters
						if action.filters and #action.filters > 0 then
							checkType(action.filters, 'table')
							
							filter_flag = true
							-- execute all filters bound to this handler
							for _, filter_name in ipairs(action.filters) do
								local name_part, args_part = filter_name:trim():match("^([%w_]+):? *([%w_ /%-]*)")
								local args_list = {}
								if args_part and args_part ~= '' then
									args_list = args_part:trim():split(' +')
								end
								local filter = getFilterByName(name_part)
								-- if filter is invalid, ignore it
								if filter then 
									local ret
									ret, propagated_params = filter(args_list, propagated_params)
									if not ret then 
										filter_flag = false 
										print(("[Warning] Filter chains was broken at %s."):format(filter_name))
										break 
									end
								else
									print(('[Warning] This filter %s is not registered.'):format(name_part))
								end
							end
							
						end
						
						-- check perms
						if action.perms and #action.perms > 0 then
							checkType(action.perms, 'table')
							-- TODO
							--
							local user = req.user
							if user then
								-- check the user's permissions
								if user.perms then
									local perms = user:getForeign('perms')
									permission_flag = permissionCheck(action.perms, perms)	
									
								end
								
								-- check groups' permissions
								if user.groups then
									local groups = user:getForeign('groups')
									for _, group in ipairs(groups) do
										if group then
											if group.perms then
												local group_perms = group:getForeign('perms')
												local ret = permissionCheck(action.perms, group_perms)
												-- once a group's permissions fit action_perms, return true
												if ret then permission_flag = true; break end
											end
										end
									end
								end
							end
						end
					
						if not filter_flag or not permission_flag then
							print("[Prompt] user was denied to execute this handler.")
							return false
						end

						-- execute handler
						-- after execute filters and permissions check, pass here, then execute this handler
						local ret, propagated_params = fun(web, req, propagated_params)
						
						-- check post filters
						local action_post_filters = action.post_filters
						if ret and action_post_filters and #action_post_filters > 0 then
							checkType(action_post_filters, 'table')
							
							filter_flag = true
							-- execute all filters bound to this handler
							for _, filter_name in ipairs(action_post_filters) do
								local name_part, args_part = filter_name:trim():match("^([%w_]+):? *([%w_ /%-]*)")
								local args_list = {}
								if args_part and args_part ~= '' then
									args_list = args_part:trim():split(' +')
								end
								local filter = getPostFilterByName(name_part)
								-- if filter is invalid, ignore it
								if filter then 
									ret, propagated_params = filter(args_list, propagated_params)
									if not ret then 
										filter_flag = false 
										print(("[Warning] PostFilter chains was broken at %s."):format(filter_name))
										break 
									end
								else
									print(('[Warning] This post filter %s is not registered.'):format(name_part))
								end
							end
							
						end
					
						-- return from lua function
						return ret
					end
				end
			end
			
			if mdl.init and type(mdl.init) == 'function' and not exclude_flag then
				nfun = function (web, req)
					local ret = mdl.init(extra_params)
					if ret then
						return actionTransform(web, req)(web, req, propagated_params)
					end
					
					-- make no sense
					return false
				end
			else
				nfun = actionTransform(web, req, propagated_params)
			end

			URLS[nurl] = nfun
		end
	end
end

------------------------------------------------------------------------
MODEL_LIST = {}

local function getClassName(model)
	return model.__tag:match('%.(%w+)$')
end

registerModel = function (model)
	checkType(model, 'table')
	assert( model.__tag, 'Registered model __tag must not be missing.' )
	
	MODEL_LIST[getClassName(model)] = model
end

getModelByName = function (name)
	checkType(name, 'string')
	assert(MODEL_LIST[name], ('[ERROR] This model %s is not registered!'):format(name))
	return MODEL_LIST[name]
end

------------------------------------------------------------------------
FILTER_LIST = {}

registerFilter = function ( filter_name, filter_func)
	checkType(filter_name, filter_func, 'string', 'function')
	
	FILTER_LIST[filter_name] = filter_func
end

getFilterByName = function ( filter_name )
	checkType(filter_name, 'string')
	
	local filter = FILTER_LIST[filter_name]
	if not filter then
		print(("[Warning] This filter %s is not registered!"):format(filter_name))
	end
	
	return filter
end


--- used mainly in entry file and each module's initial function
-- @filters   
executeFilters = function ( filters )
	checkType(filters, 'table')
	for _, filter_name in ipairs(filters) do
		local filter = getFilterByName(filter_name)
		if filter then
			-- now filter has no extra parameters
			local ret = filter()
			if not ret then
				print(("[Warning] Filter chains was broken at %s."):format(filter_name))				
				return false
			end
		end
	
	end

	return true
end

registerFilters = function (filter_table)
	checkType(filter_table, 'table')
	for _, filter_define in ipairs(filter_table) do
		registerFilter(filter_define[1], filter_define[2])
	end
end


------------------------------------------------------------------------
POST_FILTER_LIST = {}

registerPostFilter = function ( filter_name, filter_func)
	checkType(filter_name, filter_func, 'string', 'function')
	
	POST_FILTER_LIST[filter_name] = filter_func
end

getPostFilterByName = function ( filter_name )
	checkType(filter_name, 'string')
	
	local filter = POST_FILTER_LIST[filter_name]
	if not filter then
		print(("[Warning] This post filter %s is not registered!"):format(filter_name))
	end
	
	return filter
end


--- used mainly in entry file and each module's initial function
-- @filters   
executePostFilters = function ( filters )
	checkType(filters, 'table')
	for _, filter_name in ipairs(filters) do
		local filter = getPostFilterByName(filter_name)
		if filter then
			-- now filter has no extra parameters
			local ret = filter()
			if not ret then
				print(("[Warning] PostFilter chains was broken at %s."):format(filter_name))				
				return false
			end
		end
	
	end

	return true
end

registerPostFilters = function (filter_table)
	checkType(filter_table, 'table')
	for _, filter_define in ipairs(filter_table) do
		registerPostFilter(filter_define[1], filter_define[2])
	end
end

------------------------------------------------------------------------
PERMISSION_LIST = {}

registerPermission = function (name, desc, failure_func, success_func)
	local Permission = require 'bamboo.models.permission'
	checkType(name, 'string')
	local desc = desc or ''
	if failure_func then
		checkType(failure_func, 'function')
	end
	
	if success_func then
		checkType(success_func, 'function')
	end

	Permission:add(name, desc)
	PERMISSION_LIST[name] = {
		name = name,
		desc = desc,
		failure_func = failure_func,
		success_func = success_func
	}

end

registerPermissions = function (perm_t)
	checkType(perm_t, 'table')
	for _, perm_params in ipairs(perm_t) do
		registerPermission(perm_params[1], perm_params[2], 
			perm_params[3], perm_params[4])
	end

end

getPermissionByName = function (name)
	checkType(name, 'string')
	
	return PERMISSION_LIST[name]
end

------------------------------------------------------------------------
-- MENUS is a list，rather than dict。every list item has a dict in it
--MENUS = {}

---- here, menu_item probaly is item，or item list
--registerMenu = function (menu_item)
	--checkType(menu_item, 'table')
	
    -- if it is a signle item
 	--if menu_item['name'] then
		---- 
		--table.append(MENUS, menu_item)
	--else
	---- 
		--for i, v in ipairs(menu_item) do
			--table.append(MENUS, v)
		--end
	--end
--end



